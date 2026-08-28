//! Closed-GOP pack candidates, commit, and startup rollback.

use crate::{StoreError, Vault};
use afterray_protocol::{GopFrameView, GopSegmentView};
use rusqlite::{OptionalExtension, params};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

pub const IDLE_GAP_MS: i64 = 30_000;
// @dec:tiered-evidence-retention — docs/decisions/active/architecture/2026-08-27-tiered-evidence-retention.md
/// Do not let a caught-up packer emit short GOPs. At the default 10-second
/// capture interval, thirty frames is about five minutes of evidence and
/// amortizes keyframe, IVF, row, and encrypted-file overhead.
pub const MIN_PACK_FRAMES: usize = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackPolicy {
    pub hot_window_ms: i64,
    pub hot_min_stills: usize,
    pub ocr_grace_ms: i64,
    pub keyint: u16,
}

impl Default for PackPolicy {
    fn default() -> Self {
        Self {
            hot_window_ms: 7_200_000,
            hot_min_stills: 360,
            ocr_grace_ms: 600_000,
            keyint: 30,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackCandidate {
    pub id: String,
    pub captured_at_ms: i64,
    pub image_artifact_id: String,
    pub bundle_identifier: Option<String>,
    pub application_name: Option<String>,
    pub width: u32,
    pub height: u32,
}

impl PackCandidate {
    #[must_use]
    pub fn identity_key(&self) -> (&Option<String>, &Option<String>) {
        (&self.bundle_identifier, &self.application_name)
    }
}

#[derive(Debug, Clone)]
pub struct GopCommitFrame {
    pub index: u16,
    pub is_keyframe: bool,
    pub byte_offset: u32,
    pub byte_length: u32,
    pub content_hash: [u8; 32],
}

#[derive(Debug, Clone)]
pub struct GopCommitRequest<'a> {
    pub moment_ids: &'a [String],
    pub ivf: &'a [u8],
    pub codec: &'a str,
    pub encoder: &'a str,
    pub encoder_version: &'a str,
    pub width: u32,
    pub height: u32,
    pub keyint: u16,
    pub quality_quantizer: u16,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub content_hash: &'a str,
    pub frames: &'a [GopCommitFrame],
}

#[derive(Debug, Clone)]
pub struct GopSegmentRecord {
    pub id: String,
    pub artifact_id: String,
    pub codec: String,
    pub encoder: String,
    pub width: u32,
    pub height: u32,
    pub frame_count: u16,
    pub keyint: u16,
    pub quality_quantizer: u16,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub status: String,
}

#[derive(Debug, Clone)]
pub struct GopFrameRow {
    pub index: u16,
    pub moment_id: String,
    pub captured_at_ms: i64,
    pub is_keyframe: bool,
    pub byte_offset: u32,
    pub byte_length: u32,
}

#[derive(Debug, Clone)]
pub struct GopRewriteRequest<'a> {
    pub segment_id: &'a str,
    pub moment_ids: &'a [String],
    pub ivf: &'a [u8],
    pub encoder: &'a str,
    pub encoder_version: &'a str,
    pub quality_quantizer: u16,
    pub content_hash: &'a str,
    pub frames: &'a [GopCommitFrame],
}

#[derive(Debug, Clone)]
pub struct GopMergeRequest<'a> {
    pub source_segments: &'a [GopSegmentRecord],
    pub moment_ids: &'a [String],
    pub ivf: &'a [u8],
    pub codec: &'a str,
    pub encoder: &'a str,
    pub encoder_version: &'a str,
    pub width: u32,
    pub height: u32,
    pub keyint: u16,
    pub quality_quantizer: u16,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub content_hash: &'a str,
    pub frames: &'a [GopCommitFrame],
}

#[derive(Debug, Clone, Serialize)]
pub struct GopPackJob {
    pub id: String,
    pub state: String,
    pub created_at_ms: i64,
    pub error: Option<String>,
}

/// Job and segment counts for `PackStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackStatusCounts {
    pub running: u64,
    pub done: u64,
    pub failed: u64,
    pub ready: u64,
    pub ready_frames: u64,
    pub one_frame_segments: u64,
}

/// Fold pack candidates into closed-GOP runs.
///
/// One open run per `(width, height)`. App switches stay in the same GOP so
/// A↔B flicker does not collapse into one-frame stills. Display-focus flicker
/// across two monitors of different pixel sizes used to cut on every frame
/// (`size_changed` on a single wall-clock stream); those frames now join the
/// run for their own resolution.
///
/// A run closes when it hits `keyint`, or when the wall-clock stream is idle
/// (`IDLE_GAP_MS` with no frame of any size). A hole filled only by the other
/// resolution is not idle — the user was on the other display.
#[must_use]
pub fn fold_pack_runs(candidates: &[PackCandidate], keyint: u16) -> Vec<Vec<PackCandidate>> {
    let keyint = usize::from(keyint.max(1));
    let mut open: HashMap<(u32, u32), Vec<PackCandidate>> = HashMap::new();
    let mut closed: Vec<Vec<PackCandidate>> = Vec::new();
    let mut last_wall_ms: Option<i64> = None;
    for candidate in candidates {
        if let Some(previous_ms) = last_wall_ms
            && candidate.captured_at_ms.saturating_sub(previous_ms) > IDLE_GAP_MS
        {
            closed.extend(drain_open_runs(&mut open));
        }
        last_wall_ms = Some(candidate.captured_at_ms);
        let key = (candidate.width, candidate.height);
        open.entry(key).or_default().push(candidate.clone());
        if open.get(&key).is_some_and(|run| run.len() >= keyint)
            && let Some(run) = open.remove(&key)
        {
            closed.push(run);
        }
    }
    closed.extend(drain_open_runs(&mut open));
    sort_runs_oldest_first(&mut closed);
    closed
}

/// Oldest runnable GOP: leave short runs as stills until thirty compatible
/// frames are available instead of paying one keyframe and encrypted file per
/// small island.
#[must_use]
pub fn first_packable_run(runs: Vec<Vec<PackCandidate>>) -> Option<Vec<PackCandidate>> {
    runs.into_iter().find(|run| run.len() >= MIN_PACK_FRAMES)
}

/// Frames the packer will actually encode — share with `compute_backlog` so
/// leftover singles cannot pin "start now" above zero.
#[must_use]
pub fn packable_frame_count(candidates: &[PackCandidate], keyint: u16) -> usize {
    fold_pack_runs(candidates, keyint)
        .into_iter()
        .filter(|run| run.len() >= MIN_PACK_FRAMES)
        .map(|run| run.len())
        .sum()
}

fn drain_open_runs(open: &mut HashMap<(u32, u32), Vec<PackCandidate>>) -> Vec<Vec<PackCandidate>> {
    open.drain()
        .map(|(_, run)| run)
        .filter(|run| !run.is_empty())
        .collect()
}

fn sort_runs_oldest_first(runs: &mut [Vec<PackCandidate>]) {
    runs.sort_by(|left, right| {
        let left_key = left
            .first()
            .map(|frame| (frame.captured_at_ms, frame.id.as_str()));
        let right_key = right
            .first()
            .map(|frame| (frame.captured_at_ms, frame.id.as_str()));
        left_key.cmp(&right_key)
    });
}

/// Which stills may be packed, as one predicate over `moments m`.
///
/// Shared with `list_pack_candidates`. The dashboard number is
/// `packable_frame_count` over that list, not a raw `COUNT(*)` — leftover
/// 1-frame runs are not drainable. Bind order: `?1` hot-window cutoff,
/// `?2` hot-still floor, `?3` OCR grace cutoff.
pub(crate) const PACK_CANDIDATE_PREDICATE: &str = "m.gop_segment_id IS NULL
            AND m.image_artifact_id IS NOT NULL
            AND m.width IS NOT NULL AND m.height IS NOT NULL
            AND lower(coalesce(m.application_name, '')) != 'loginwindow'
            AND lower(coalesce(m.bundle_identifier, '')) NOT LIKE '%loginwindow%'
            AND m.captured_at_ms <= ?1
            AND m.id NOT IN (
                SELECT id FROM moments ORDER BY captured_at_ms DESC, id DESC LIMIT ?2
            )
            AND (
                EXISTS (
                    SELECT 1 FROM text_evidence te
                     WHERE te.moment_id = m.id AND te.source = 'ocr'
                )
                OR m.captured_at_ms <= ?3
            )";

impl Vault {
    pub fn rollback_orphan_gops(&self) -> Result<usize, StoreError> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        let writing: Vec<String> = {
            let mut statement = transaction.prepare(
                "SELECT id FROM gop_segments WHERE status IN ('writing', 'failed')
                 UNION
                 SELECT segment_id FROM gop_pack_jobs
                  WHERE state IN ('pending', 'running') AND segment_id IS NOT NULL",
            )?;
            statement
                .query_map([], |row| row.get(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut artifact_ids = Vec::new();
        for segment_id in &writing {
            transaction.execute(
                "UPDATE moments SET gop_segment_id = NULL, gop_index = NULL
                  WHERE gop_segment_id = ?1",
                [segment_id],
            )?;
            let artifact_id: Option<String> = transaction
                .query_row(
                    "SELECT artifact_id FROM gop_segments WHERE id = ?1",
                    [segment_id],
                    |row| row.get(0),
                )
                .optional()?;
            transaction.execute("DELETE FROM gop_frames WHERE segment_id = ?1", [segment_id])?;
            transaction.execute("DELETE FROM gop_segments WHERE id = ?1", [segment_id])?;
            if let Some(artifact_id) = artifact_id {
                transaction.execute("DELETE FROM artifacts WHERE id = ?1", [&artifact_id])?;
                artifact_ids.push(artifact_id);
            }
        }
        transaction.execute(
            "UPDATE gop_pack_jobs
                SET state = 'failed',
                    error = COALESCE(error, 'orphaned by process restart'),
                    updated_at_ms = CAST(strftime('%s','now') AS INTEGER) * 1000
              WHERE state IN ('pending', 'running')",
            [],
        )?;
        transaction.commit()?;
        drop(connection);
        for artifact_id in &artifact_ids {
            let _ = std::fs::remove_file(self.artifact_path(artifact_id));
        }
        Ok(writing.len())
    }

    pub fn list_pack_candidates(
        &self,
        now_ms: i64,
        policy: &PackPolicy,
    ) -> Result<Vec<PackCandidate>, StoreError> {
        Self::pack_candidates_on(&self.connection.lock().unwrap(), now_ms, policy)
    }

    /// Same selection as [`Self::list_pack_candidates`], on the reader pool.
    /// Dashboard polling must not take the writer.
    pub fn list_pack_candidates_read(
        &self,
        now_ms: i64,
        policy: &PackPolicy,
    ) -> Result<Vec<PackCandidate>, StoreError> {
        Self::pack_candidates_on(&self.readers.get(), now_ms, policy)
    }

    fn pack_candidates_on(
        connection: &rusqlite::Connection,
        now_ms: i64,
        policy: &PackPolicy,
    ) -> Result<Vec<PackCandidate>, StoreError> {
        let cutoff = now_ms.saturating_sub(policy.hot_window_ms);
        let ocr_cutoff = now_ms.saturating_sub(policy.ocr_grace_ms);
        let floor = i64::try_from(policy.hot_min_stills).unwrap_or(i64::MAX);
        let mut statement = connection.prepare(&format!(
            "SELECT m.id, m.captured_at_ms, m.image_artifact_id,
                        m.bundle_identifier, m.application_name, m.width, m.height
                   FROM moments m
                  WHERE {PACK_CANDIDATE_PREDICATE}
                  ORDER BY m.captured_at_ms ASC, m.id ASC"
        ))?;
        let rows = statement.query_map(params![cutoff, floor, ocr_cutoff], |row| {
            Ok(PackCandidate {
                id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                image_artifact_id: row.get(2)?,
                bundle_identifier: row.get(3)?,
                application_name: row.get(4)?,
                width: u32::try_from(row.get::<_, i64>(5)?).unwrap_or(0),
                height: u32::try_from(row.get::<_, i64>(6)?).unwrap_or(0),
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn insert_pack_job(&self, now_ms: i64, payload_json: &str) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        self.connection.lock().unwrap().execute(
            "INSERT INTO gop_pack_jobs
             (id, state, attempts, created_at_ms, updated_at_ms, heartbeat_at_ms, payload_json)
             VALUES (?1, 'running', 1, ?2, ?2, ?2, ?3)",
            params![id, now_ms, payload_json],
        )?;
        Ok(id)
    }

    pub fn finish_pack_job(
        &self,
        job_id: &str,
        now_ms: i64,
        segment_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), StoreError> {
        let state = if error.is_some() { "failed" } else { "done" };
        self.connection.lock().unwrap().execute(
            "UPDATE gop_pack_jobs
                SET state = ?2,
                    segment_id = COALESCE(?3, segment_id),
                    updated_at_ms = ?4,
                    heartbeat_at_ms = ?4,
                    error = ?5
              WHERE id = ?1",
            params![job_id, state, segment_id, now_ms, error],
        )?;
        Ok(())
    }

    pub fn heartbeat_pack_job(&self, job_id: &str, now_ms: i64) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE gop_pack_jobs SET heartbeat_at_ms = ?2, updated_at_ms = ?2 WHERE id = ?1",
            params![job_id, now_ms],
        )?;
        Ok(())
    }

    pub fn pack_status_counts(&self) -> Result<PackStatusCounts, StoreError> {
        let connection = self.readers.get();
        let running = count_where(&connection, "gop_pack_jobs", "state = 'running'")?;
        let done = count_where(&connection, "gop_pack_jobs", "state = 'done'")?;
        let failed = count_where(&connection, "gop_pack_jobs", "state = 'failed'")?;
        let ready = count_where(&connection, "gop_segments", "status = 'ready'")?;
        let (ready_frames, one_frame_segments): (i64, i64) = connection.query_row(
            "SELECT COALESCE(SUM(frame_count), 0),
                    COALESCE(SUM(CASE WHEN frame_count = 1 THEN 1 ELSE 0 END), 0)
               FROM gop_segments WHERE status = 'ready'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        Ok(PackStatusCounts {
            running,
            done,
            failed,
            ready,
            ready_frames: u64::try_from(ready_frames).unwrap_or(0),
            one_frame_segments: u64::try_from(one_frame_segments).unwrap_or(0),
        })
    }

    pub fn commit_gop(&self, request: GopCommitRequest<'_>) -> Result<String, StoreError> {
        if request.moment_ids.is_empty() || request.frames.len() != request.moment_ids.len() {
            return Err(StoreError::GopStale);
        }
        let _artifact_guard = self.artifact_io.write().unwrap();
        let staged = self.stage_artifact_unlocked("video/x-ivf; codec=av01", request.ivf)?;
        let segment_id = Uuid::now_v7().to_string();
        let frame_count =
            i64::try_from(request.frames.len()).map_err(|_| StoreError::GopFrameCountOverflow)?;
        let result = (|| {
            let mut connection = self.connection.lock().unwrap();
            let transaction = connection.transaction()?;
            transaction.execute(
                "INSERT INTO artifacts (
                     id, content_type, byte_length, format_version, wrapped_key, wrapping_nonce
                 ) VALUES (?1, ?2, ?3, 1, ?4, ?5)",
                params![
                    staged.id,
                    staged.content_type,
                    staged.byte_length,
                    staged.wrapped_dek,
                    staged.wrapping_nonce,
                ],
            )?;
            for moment_id in request.moment_ids {
                let present: Option<String> = transaction
                    .query_row(
                        "SELECT id FROM moments
                          WHERE id = ?1 AND gop_segment_id IS NULL AND image_artifact_id IS NOT NULL",
                        [moment_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if present.is_none() {
                    return Err(StoreError::GopStale);
                }
            }
            transaction.execute(
                "INSERT INTO gop_segments (
                     id, artifact_id, codec, encoder, encoder_version,
                     width, height, frame_count, keyint, started_at_ms, ended_at_ms,
                     status, content_hash, quality_quantizer
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'writing', ?12, ?13)",
                params![
                    segment_id,
                    staged.id,
                    request.codec,
                    request.encoder,
                    request.encoder_version,
                    i64::from(request.width),
                    i64::from(request.height),
                    frame_count,
                    i64::from(request.keyint),
                    request.started_at_ms,
                    request.ended_at_ms,
                    request.content_hash,
                    i64::from(request.quality_quantizer),
                ],
            )?;
            for (moment_id, frame) in request.moment_ids.iter().zip(request.frames.iter()) {
                transaction.execute(
                    "INSERT INTO gop_frames (
                         segment_id, frame_index, moment_id, is_keyframe,
                         byte_offset, byte_length, content_hash
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        segment_id,
                        i64::from(frame.index),
                        moment_id,
                        i64::from(frame.is_keyframe),
                        i64::from(frame.byte_offset),
                        i64::from(frame.byte_length),
                        hex_hash(&frame.content_hash),
                    ],
                )?;
            }
            let mut claimed = 0_usize;
            for (index, moment_id) in request.moment_ids.iter().enumerate() {
                let index = i64::try_from(index).map_err(|_| StoreError::GopFrameCountOverflow)?;
                claimed += transaction.execute(
                    "UPDATE moments
                        SET gop_segment_id = ?1, gop_index = ?2
                      WHERE id = ?3 AND gop_segment_id IS NULL",
                    params![segment_id, index, moment_id],
                )?;
            }
            if claimed != request.moment_ids.len() {
                return Err(StoreError::GopStale);
            }
            transaction.commit()?;
            Ok(())
        })();
        if let Err(error) = result {
            self.discard_staged_artifact(&staged.id);
            return Err(error);
        }
        Ok(segment_id)
    }

    /// Atomically swaps one ready GOP for a lower-quality encode with the same
    /// ordered moments. The new encrypted file is staged first; readers see
    /// either the complete old metadata or the complete new metadata, never a
    /// half-rewritten frame table.
    pub fn rewrite_gop(&self, request: GopRewriteRequest<'_>) -> Result<(), StoreError> {
        if request.moment_ids.is_empty() || request.frames.len() != request.moment_ids.len() {
            return Err(StoreError::GopStale);
        }
        let _artifact_guard = self.artifact_io.write().unwrap();
        let staged = self.stage_artifact_unlocked("video/x-ivf; codec=av01", request.ivf)?;
        let result = (|| {
            let mut connection = self.connection.lock().unwrap();
            let transaction = connection.transaction()?;
            let old_artifact_id: String = transaction
                .query_row(
                    "SELECT artifact_id FROM gop_segments
                      WHERE id = ?1 AND status = 'ready'",
                    [request.segment_id],
                    |row| row.get(0),
                )
                .optional()?
                .ok_or_else(|| StoreError::GopNotFound(request.segment_id.to_owned()))?;
            let current_moments: Vec<String> = {
                let mut statement = transaction.prepare(
                    "SELECT moment_id FROM gop_frames
                      WHERE segment_id = ?1 ORDER BY frame_index",
                )?;
                statement
                    .query_map([request.segment_id], |row| row.get(0))?
                    .collect::<Result<Vec<_>, _>>()?
            };
            if current_moments != request.moment_ids {
                return Err(StoreError::GopStale);
            }
            transaction.execute(
                "INSERT INTO artifacts (
                     id, content_type, byte_length, format_version, wrapped_key, wrapping_nonce
                 ) VALUES (?1, ?2, ?3, 1, ?4, ?5)",
                params![
                    staged.id,
                    staged.content_type,
                    staged.byte_length,
                    staged.wrapped_dek,
                    staged.wrapping_nonce,
                ],
            )?;
            transaction.execute(
                "DELETE FROM gop_frames WHERE segment_id = ?1",
                [request.segment_id],
            )?;
            for (moment_id, frame) in request.moment_ids.iter().zip(request.frames.iter()) {
                transaction.execute(
                    "INSERT INTO gop_frames (
                         segment_id, frame_index, moment_id, is_keyframe,
                         byte_offset, byte_length, content_hash
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        request.segment_id,
                        i64::from(frame.index),
                        moment_id,
                        i64::from(frame.is_keyframe),
                        i64::from(frame.byte_offset),
                        i64::from(frame.byte_length),
                        hex_hash(&frame.content_hash),
                    ],
                )?;
            }
            transaction.execute(
                "UPDATE gop_segments
                    SET artifact_id = ?2,
                        encoder = ?3,
                        encoder_version = ?4,
                        frame_count = ?5,
                        keyint = ?6,
                        content_hash = ?7,
                        quality_quantizer = ?8
                  WHERE id = ?1",
                params![
                    request.segment_id,
                    staged.id,
                    request.encoder,
                    request.encoder_version,
                    i64::try_from(request.frames.len()).unwrap_or(i64::MAX),
                    i64::try_from(request.frames.len()).unwrap_or(i64::MAX),
                    request.content_hash,
                    i64::from(request.quality_quantizer),
                ],
            )?;
            transaction.execute("DELETE FROM artifacts WHERE id = ?1", [&old_artifact_id])?;
            transaction.commit()?;
            Ok(old_artifact_id)
        })();
        let old_artifact_id = match result {
            Ok(id) => id,
            Err(error) => {
                self.discard_staged_artifact(&staged.id);
                return Err(error);
            }
        };
        let _ = std::fs::remove_file(self.artifact_path(&old_artifact_id));
        Ok(())
    }

    /// Atomically replaces consecutive compatible GOPs with one closed GOP.
    /// The caller must have decoded and re-encoded the exact ordered moments;
    /// artifact ids provide the compare-and-swap token against a concurrent
    /// quality rewrite or retention sweep.
    #[allow(clippy::too_many_lines)]
    pub fn merge_gops(&self, request: GopMergeRequest<'_>) -> Result<String, StoreError> {
        if request.source_segments.len() < 2
            || request.moment_ids.is_empty()
            || request.frames.len() != request.moment_ids.len()
            || request.frames.len() > MIN_PACK_FRAMES
        {
            return Err(StoreError::GopStale);
        }
        let source_ids = request
            .source_segments
            .iter()
            .map(|segment| segment.id.as_str())
            .collect::<HashSet<_>>();
        if source_ids.len() != request.source_segments.len()
            || request
                .source_segments
                .iter()
                .map(|segment| usize::from(segment.frame_count))
                .sum::<usize>()
                != request.moment_ids.len()
            || request.source_segments.iter().any(|segment| {
                segment.codec != request.codec
                    || segment.width != request.width
                    || segment.height != request.height
                    || segment.quality_quantizer > request.quality_quantizer
                    || segment.status != "ready"
            })
            || request
                .source_segments
                .windows(2)
                .any(|pair| !gop_segments_are_contiguous(&pair[0], &pair[1]))
            || request
                .source_segments
                .first()
                .is_none_or(|segment| segment.started_at_ms != request.started_at_ms)
            || request
                .source_segments
                .last()
                .is_none_or(|segment| segment.ended_at_ms != request.ended_at_ms)
        {
            return Err(StoreError::GopStale);
        }

        let _artifact_guard = self.artifact_io.write().unwrap();
        let staged = self.stage_artifact_unlocked("video/x-ivf; codec=av01", request.ivf)?;
        let segment_id = Uuid::now_v7().to_string();
        let result = (|| {
            let mut connection = self.connection.lock().unwrap();
            let transaction = connection.transaction()?;
            let mut old_artifact_ids = Vec::with_capacity(request.source_segments.len());
            let mut current_moments = Vec::with_capacity(request.moment_ids.len());

            for source in request.source_segments {
                let current: Option<(String, String, i64, i64, i64)> = transaction
                    .query_row(
                        "SELECT artifact_id, codec, width, height, quality_quantizer
                           FROM gop_segments
                          WHERE id = ?1 AND status = 'ready'",
                        [&source.id],
                        |row| {
                            Ok((
                                row.get(0)?,
                                row.get(1)?,
                                row.get(2)?,
                                row.get(3)?,
                                row.get(4)?,
                            ))
                        },
                    )
                    .optional()?;
                let Some((artifact_id, codec, width, height, quality_quantizer)) = current else {
                    return Err(StoreError::GopStale);
                };
                if artifact_id != source.artifact_id
                    || codec != source.codec
                    || width != i64::from(source.width)
                    || height != i64::from(source.height)
                    || quality_quantizer != i64::from(source.quality_quantizer)
                {
                    return Err(StoreError::GopStale);
                }
                let rows: Vec<String> = {
                    let mut statement = transaction.prepare(
                        "SELECT moment_id FROM gop_frames
                          WHERE segment_id = ?1 ORDER BY frame_index",
                    )?;
                    statement
                        .query_map([&source.id], |row| row.get(0))?
                        .collect::<Result<Vec<_>, _>>()?
                };
                if rows.len() != usize::from(source.frame_count) {
                    return Err(StoreError::GopStale);
                }
                current_moments.extend(
                    rows.into_iter()
                        .map(|moment_id| (moment_id, source.id.clone())),
                );
                old_artifact_ids.push(artifact_id);
            }
            if current_moments
                .iter()
                .map(|(moment_id, _)| moment_id)
                .ne(request.moment_ids.iter())
            {
                return Err(StoreError::GopStale);
            }

            transaction.execute(
                "INSERT INTO artifacts (
                     id, content_type, byte_length, format_version, wrapped_key, wrapping_nonce
                 ) VALUES (?1, ?2, ?3, 1, ?4, ?5)",
                params![
                    staged.id,
                    staged.content_type,
                    staged.byte_length,
                    staged.wrapped_dek,
                    staged.wrapping_nonce,
                ],
            )?;
            transaction.execute(
                "INSERT INTO gop_segments (
                     id, artifact_id, codec, encoder, encoder_version,
                     width, height, frame_count, keyint, started_at_ms, ended_at_ms,
                     status, content_hash, quality_quantizer
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'ready', ?12, ?13)",
                params![
                    segment_id,
                    staged.id,
                    request.codec,
                    request.encoder,
                    request.encoder_version,
                    i64::from(request.width),
                    i64::from(request.height),
                    i64::try_from(request.frames.len()).unwrap_or(i64::MAX),
                    i64::from(request.keyint),
                    request.started_at_ms,
                    request.ended_at_ms,
                    request.content_hash,
                    i64::from(request.quality_quantizer),
                ],
            )?;
            for source in request.source_segments {
                transaction
                    .execute("DELETE FROM gop_frames WHERE segment_id = ?1", [&source.id])?;
            }
            for (moment_id, frame) in request.moment_ids.iter().zip(request.frames.iter()) {
                transaction.execute(
                    "INSERT INTO gop_frames (
                         segment_id, frame_index, moment_id, is_keyframe,
                         byte_offset, byte_length, content_hash
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        segment_id,
                        i64::from(frame.index),
                        moment_id,
                        i64::from(frame.is_keyframe),
                        i64::from(frame.byte_offset),
                        i64::from(frame.byte_length),
                        hex_hash(&frame.content_hash),
                    ],
                )?;
            }
            for (index, (moment_id, old_segment_id)) in current_moments.iter().enumerate() {
                let changed = transaction.execute(
                    "UPDATE moments
                        SET gop_segment_id = ?1, gop_index = ?2
                      WHERE id = ?3 AND gop_segment_id = ?4",
                    params![
                        segment_id,
                        i64::try_from(index).unwrap_or(i64::MAX),
                        moment_id,
                        old_segment_id
                    ],
                )?;
                if changed != 1 {
                    return Err(StoreError::GopStale);
                }
            }
            for source in request.source_segments {
                transaction.execute(
                    "UPDATE gop_pack_jobs SET segment_id = ?1 WHERE segment_id = ?2",
                    params![segment_id, source.id],
                )?;
                transaction.execute("DELETE FROM gop_segments WHERE id = ?1", [&source.id])?;
            }
            for artifact_id in &old_artifact_ids {
                transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
            }
            transaction.commit()?;
            Ok(old_artifact_ids)
        })();
        let old_artifact_ids = match result {
            Ok(ids) => ids,
            Err(error) => {
                self.discard_staged_artifact(&staged.id);
                return Err(error);
            }
        };
        for artifact_id in old_artifact_ids {
            let _ = std::fs::remove_file(self.artifact_path(&artifact_id));
        }
        Ok(segment_id)
    }

    /// Oldest run of consecutive, same-resolution AV1 segments that can be
    /// collapsed into one GOP without exceeding thirty frames. Source quality
    /// may differ because compact selects a single no-better output tier.
    pub fn next_gop_merge_candidate(&self) -> Result<Option<Vec<GopSegmentRecord>>, StoreError> {
        let connection = self.readers.get();
        let cutoff: Option<i64> = connection.query_row(
            "SELECT MIN(started_at_ms) FROM gop_segments
              WHERE status = 'ready' AND codec = 'av01'
                AND frame_count > 0 AND frame_count < ?1",
            [i64::try_from(MIN_PACK_FRAMES).unwrap_or(i64::MAX)],
            |row| row.get(0),
        )?;
        let Some(cutoff) = cutoff else {
            return Ok(None);
        };
        let mut statement = connection.prepare(
            "SELECT id, artifact_id, codec, encoder, width, height,
                    frame_count, keyint, quality_quantizer,
                    started_at_ms, ended_at_ms, status
               FROM gop_segments
              WHERE status = 'ready' AND ended_at_ms >= ?1
              ORDER BY started_at_ms ASC, ended_at_ms ASC, id ASC",
        )?;
        let segments = statement
            .query_map([cutoff], map_gop_segment)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(first_mergeable_gop_group(&segments, MIN_PACK_FRAMES))
    }

    pub fn next_gop_quality_candidate(
        &self,
        now_ms: i64,
        first_quantizer: u16,
        second_quantizer: u16,
        worst_quantizer: u16,
    ) -> Result<Option<GopSegmentRecord>, StoreError> {
        const DAY_MS: i64 = 24 * 60 * 60 * 1000;
        let seven_days = now_ms.saturating_sub(7 * DAY_MS);
        let fourteen_days = now_ms.saturating_sub(14 * DAY_MS);
        let twenty_eight_days = now_ms.saturating_sub(28 * DAY_MS);
        let id: Option<String> = self
            .readers
            .get()
            .query_row(
                "SELECT id FROM gop_segments
                  WHERE status = 'ready'
                    AND quality_quantizer < CASE
                      WHEN ended_at_ms < ?1 THEN ?4
                      WHEN ended_at_ms < ?2 THEN ?3
                      WHEN ended_at_ms < ?5 THEN ?6
                      ELSE quality_quantizer
                    END
                  ORDER BY ended_at_ms ASC, id ASC
                  LIMIT 1",
                params![
                    twenty_eight_days,
                    fourteen_days,
                    second_quantizer,
                    worst_quantizer,
                    seven_days,
                    first_quantizer,
                ],
                |row| row.get(0),
            )
            .optional()?;
        id.map(|id| self.gop_segment(&id)).transpose()
    }

    /// A representative ready GOP, the total encrypted-payload byte count, and
    /// the bytes that would still be degraded at `target_quantizer`.
    ///
    /// Prefer the best available source quality, then the largest segment, so
    /// the preview does not add another generation of loss to an already-aged
    /// sample when an original-quality GOP is available.
    pub fn gop_quality_preview_candidate(
        &self,
        target_quantizer: u16,
    ) -> Result<Option<(GopSegmentRecord, u64, u64)>, StoreError> {
        let connection = self.readers.get();
        let (total, degradable): (i64, i64) = connection.query_row(
            "SELECT COALESCE(SUM(a.byte_length), 0),
                    COALESCE(SUM(CASE WHEN gs.quality_quantizer < ?1
                                      THEN a.byte_length ELSE 0 END), 0)
               FROM gop_segments gs
               JOIN artifacts a ON a.id = gs.artifact_id
              WHERE gs.status = 'ready'",
            [i64::from(target_quantizer)],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let id = connection
            .query_row(
                "SELECT gs.id
                   FROM gop_segments gs
                   JOIN artifacts a ON a.id = gs.artifact_id
                  WHERE gs.status = 'ready'
                  ORDER BY CASE WHEN gs.quality_quantizer < ?1 THEN 0 ELSE 1 END,
                           gs.quality_quantizer ASC,
                           a.byte_length DESC,
                           gs.ended_at_ms DESC
                  LIMIT 1",
                [i64::from(target_quantizer)],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        drop(connection);
        id.map(|id| {
            self.gop_segment(&id).map(|segment| {
                (
                    segment,
                    u64::try_from(total).unwrap_or(0),
                    u64::try_from(degradable).unwrap_or(0),
                )
            })
        })
        .transpose()
    }

    pub fn mark_gop_ready(&self, segment_id: &str) -> Result<(), StoreError> {
        let changed = self.connection.lock().unwrap().execute(
            "UPDATE gop_segments SET status = 'ready' WHERE id = ?1 AND status = 'writing'",
            [segment_id],
        )?;
        if changed != 1 {
            return Err(StoreError::GopNotFound(segment_id.to_owned()));
        }
        Ok(())
    }

    pub fn gop_segment(&self, segment_id: &str) -> Result<GopSegmentRecord, StoreError> {
        self.load_gop_segment(segment_id, "ready")
    }

    fn load_gop_segment(
        &self,
        segment_id: &str,
        status: &str,
    ) -> Result<GopSegmentRecord, StoreError> {
        self.readers
            .get()
            .query_row(
                "SELECT id, artifact_id, codec, encoder, width, height,
                        frame_count, keyint, quality_quantizer,
                        started_at_ms, ended_at_ms, status
                   FROM gop_segments WHERE id = ?1 AND status = ?2",
                params![segment_id, status],
                map_gop_segment,
            )
            .optional()?
            .ok_or_else(|| StoreError::GopNotFound(segment_id.to_owned()))
    }

    pub fn live_gop_frames(&self, segment_id: &str) -> Result<Vec<GopFrameRow>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT gf.frame_index, gf.moment_id, m.captured_at_ms,
                    gf.is_keyframe, gf.byte_offset, gf.byte_length
               FROM gop_frames gf
               JOIN moments m ON m.id = gf.moment_id
              WHERE gf.segment_id = ?1 ORDER BY gf.frame_index",
        )?;
        let rows = statement.query_map([segment_id], |row| {
            Ok(GopFrameRow {
                index: u16::try_from(row.get::<_, i64>(0)?).unwrap_or(0),
                moment_id: row.get(1)?,
                captured_at_ms: row.get(2)?,
                is_keyframe: row.get::<_, i64>(3)? != 0,
                byte_offset: u32::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
                byte_length: u32::try_from(row.get::<_, i64>(5)?).unwrap_or(0),
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn gop_segment_view(&self, segment_id: &str) -> Result<GopSegmentView, StoreError> {
        let segment = self.gop_segment(segment_id)?;
        let frames = self.live_gop_frames(segment_id)?;
        Ok(GopSegmentView {
            id: segment.id,
            artifact_id: segment.artifact_id,
            codec: segment.codec,
            encoder: segment.encoder,
            width: segment.width,
            height: segment.height,
            frame_count: segment.frame_count,
            keyint: segment.keyint,
            quality_quantizer: segment.quality_quantizer,
            started_at_ms: segment.started_at_ms,
            ended_at_ms: segment.ended_at_ms,
            status: segment.status,
            frames: frames
                .into_iter()
                .map(|frame| GopFrameView {
                    index: frame.index,
                    moment_id: frame.moment_id,
                    is_keyframe: frame.is_keyframe,
                })
                .collect(),
        })
    }

    pub fn read_gop_artifact(
        &self,
        segment_id: &str,
    ) -> Result<afterray_protocol::ArtifactPayload, StoreError> {
        let segment = self.gop_segment(segment_id)?;
        self.read_artifact(&segment.artifact_id)
    }

    pub fn read_gop_artifact_writing(
        &self,
        segment_id: &str,
    ) -> Result<afterray_protocol::ArtifactPayload, StoreError> {
        let segment = self.load_gop_segment(segment_id, "writing")?;
        self.read_artifact(&segment.artifact_id)
    }

    /// Undo a ready GOP (verify failed or operator abort). Moments keep their JPEGs.
    pub fn abort_gop(&self, segment_id: &str) -> Result<(), StoreError> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        let artifact_id: Option<String> = transaction
            .query_row(
                "SELECT artifact_id FROM gop_segments WHERE id = ?1",
                [segment_id],
                |row| row.get(0),
            )
            .optional()?;
        transaction.execute(
            "UPDATE moments SET gop_segment_id = NULL, gop_index = NULL
              WHERE gop_segment_id = ?1",
            [segment_id],
        )?;
        transaction.execute(
            "UPDATE gop_pack_jobs SET segment_id = NULL WHERE segment_id = ?1",
            [segment_id],
        )?;
        transaction.execute("DELETE FROM gop_frames WHERE segment_id = ?1", [segment_id])?;
        transaction.execute("DELETE FROM gop_segments WHERE id = ?1", [segment_id])?;
        if let Some(artifact_id) = &artifact_id {
            transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
        }
        transaction.commit()?;
        drop(connection);
        if let Some(artifact_id) = artifact_id {
            let _ = std::fs::remove_file(self.artifact_path(&artifact_id));
        }
        Ok(())
    }

    /// Drop leftover Dual JPEGs only after a GOP is ready and readable.
    pub fn reconcile_packed_stills(&self) -> Result<usize, StoreError> {
        let segment_ids: Vec<String> = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT DISTINCT m.gop_segment_id
                   FROM moments m
                   JOIN gop_segments gs ON gs.id = m.gop_segment_id
                  WHERE m.image_artifact_id IS NOT NULL
                    AND gs.status = 'ready'",
            )?;
            statement
                .query_map([], |row| row.get(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut dropped = 0;
        for segment_id in segment_ids {
            if self.read_gop_artifact(&segment_id).is_err() {
                continue;
            }
            dropped += self.drop_unpinned_stills(&segment_id)?;
        }
        Ok(dropped)
    }

    /// Drop cold stills after a GOP is durable and verified.
    pub fn drop_unpinned_stills(&self, segment_id: &str) -> Result<usize, StoreError> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        let doomed: Vec<(String, String)> = {
            let mut statement = transaction.prepare(
                "SELECT id, image_artifact_id FROM moments
                  WHERE gop_segment_id = ?1
                    AND image_artifact_id IS NOT NULL",
            )?;
            statement
                .query_map([segment_id], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        transaction.execute(
            "UPDATE moments SET image_artifact_id = NULL
              WHERE gop_segment_id = ?1
                AND image_artifact_id IS NOT NULL",
            [segment_id],
        )?;
        for (_, artifact_id) in &doomed {
            transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
        }
        transaction.commit()?;
        drop(connection);
        for (_, artifact_id) in &doomed {
            let _ = std::fs::remove_file(self.artifact_path(artifact_id));
        }
        Ok(doomed.len())
    }
}

fn count_where(
    connection: &rusqlite::Connection,
    table: &str,
    predicate: &str,
) -> Result<u64, StoreError> {
    let sql = format!("SELECT COUNT(*) FROM {table} WHERE {predicate}");
    let count: i64 = connection.query_row(&sql, [], |row| row.get(0))?;
    Ok(u64::try_from(count).unwrap_or(0))
}

fn map_gop_segment(row: &rusqlite::Row<'_>) -> rusqlite::Result<GopSegmentRecord> {
    Ok(GopSegmentRecord {
        id: row.get(0)?,
        artifact_id: row.get(1)?,
        codec: row.get(2)?,
        encoder: row.get(3)?,
        width: u32::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
        height: u32::try_from(row.get::<_, i64>(5)?).unwrap_or(0),
        frame_count: u16::try_from(row.get::<_, i64>(6)?).unwrap_or(0),
        keyint: u16::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
        quality_quantizer: u16::try_from(row.get::<_, i64>(8)?).unwrap_or(100),
        started_at_ms: row.get(9)?,
        ended_at_ms: row.get(10)?,
        status: row.get(11)?,
    })
}

fn gop_segments_are_contiguous(left: &GopSegmentRecord, right: &GopSegmentRecord) -> bool {
    left.codec == "av01"
        && right.codec == left.codec
        && right.width == left.width
        && right.height == left.height
        && right.started_at_ms >= left.ended_at_ms
        && right.started_at_ms.saturating_sub(left.ended_at_ms) <= IDLE_GAP_MS
}

fn first_mergeable_gop_group(
    segments: &[GopSegmentRecord],
    max_frames: usize,
) -> Option<Vec<GopSegmentRecord>> {
    if max_frames < 2 {
        return None;
    }
    let mut open: HashMap<(u32, u32), Vec<GopSegmentRecord>> = HashMap::new();
    let mut candidates = Vec::new();

    for segment in segments {
        let key = (segment.width, segment.height);
        let eligible = segment.codec == "av01"
            && segment.status == "ready"
            && segment.frame_count > 0
            && usize::from(segment.frame_count) < max_frames;
        if let Some(mut group) = open.remove(&key) {
            let frame_count = group
                .iter()
                .map(|item| usize::from(item.frame_count))
                .sum::<usize>();
            let can_append = eligible
                && group
                    .last()
                    .is_some_and(|previous| gop_segments_are_contiguous(previous, segment))
                && frame_count.saturating_add(usize::from(segment.frame_count)) <= max_frames;
            if can_append {
                group.push(segment.clone());
                if frame_count + usize::from(segment.frame_count) == max_frames {
                    candidates.push(group);
                } else {
                    open.insert(key, group);
                }
                continue;
            }
            if group.len() >= 2 {
                candidates.push(group);
            }
        }
        if eligible {
            open.insert(key, vec![segment.clone()]);
        }
    }
    candidates.extend(open.into_values().filter(|group| group.len() >= 2));
    candidates.into_iter().min_by(|left, right| {
        let left = left
            .first()
            .map(|segment| (segment.started_at_ms, segment.id.as_str()));
        let right = right
            .first()
            .map(|segment| (segment.started_at_ms, segment.id.as_str()));
        left.cmp(&right)
    })
}

fn hex_hash(bytes: &[u8; 32]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(64);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(id: &str, at: i64, app: &str, bundle: &str) -> PackCandidate {
        PackCandidate {
            id: id.to_owned(),
            captured_at_ms: at,
            image_artifact_id: format!("img-{id}"),
            bundle_identifier: Some(bundle.to_owned()),
            application_name: Some(app.to_owned()),
            width: 64,
            height: 64,
        }
    }

    fn segment(
        id: &str,
        frame_count: u16,
        started_at_ms: i64,
        quality_quantizer: u16,
    ) -> GopSegmentRecord {
        GopSegmentRecord {
            id: id.to_owned(),
            artifact_id: format!("artifact-{id}"),
            codec: "av01".to_owned(),
            encoder: "rav1e".to_owned(),
            width: 64,
            height: 64,
            frame_count,
            keyint: frame_count,
            quality_quantizer,
            started_at_ms,
            ended_at_ms: started_at_ms + i64::from(frame_count.saturating_sub(1)) * 10_000,
            status: "ready".to_owned(),
        }
    }

    #[test]
    fn fold_cuts_on_resolution_not_app() {
        let frames = [
            candidate("a", 0, "Chrome", "chrome"),
            candidate("b", 10_000, "Chrome", "chrome"),
            candidate("c", 20_000, "Chrome", "chrome"),
            candidate("d", 30_000, "Feishu", "feishu"),
            candidate("e", 40_000, "Feishu", "feishu"),
            {
                let mut xcode = candidate("f", 50_000, "Xcode", "xcode");
                xcode.width = 32;
                xcode
            },
            {
                let mut half = candidate("g", 60_000, "Xcode", "xcode");
                half.width = 32;
                half.height = 32;
                half
            },
        ];
        let runs = fold_pack_runs(&frames, 30);
        assert_eq!(runs.len(), 3);
        assert_eq!(
            runs[0]
                .iter()
                .map(|frame| frame.id.as_str())
                .collect::<Vec<_>>(),
            ["a", "b", "c", "d", "e"]
        );
        assert_eq!(runs[1].len(), 1);
        assert_eq!(runs[2].len(), 1);
    }

    #[test]
    fn fold_closes_at_keyint() {
        let frames: Vec<_> = (0..31)
            .map(|index| {
                candidate(
                    &format!("m{index}"),
                    i64::from(index) * 10_000,
                    "Lody",
                    "lody",
                )
            })
            .collect();
        let runs = fold_pack_runs(&frames, 30);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].len(), 30);
        assert_eq!(runs[1].len(), 1);
    }

    #[test]
    fn fold_cuts_on_idle_gap() {
        let frames = [
            candidate("a", 0, "Lody", "lody"),
            candidate("b", 40_000, "Lody", "lody"),
        ];
        let runs = fold_pack_runs(&frames, 12);
        assert_eq!(runs.len(), 2);
    }

    #[test]
    fn fold_keeps_interleaved_apps_in_one_timeline_gop() {
        let frames = [
            candidate("a1", 0, "Chrome", "chrome"),
            candidate("b1", 10_000, "Feishu", "feishu"),
            candidate("a2", 20_000, "Chrome", "chrome"),
            candidate("b2", 30_000, "Feishu", "feishu"),
            candidate("a3", 40_000, "Chrome", "chrome"),
            candidate("b3", 50_000, "Feishu", "feishu"),
        ];
        let runs = fold_pack_runs(&frames, 30);
        assert_eq!(runs.len(), 1);
        assert_eq!(
            runs[0]
                .iter()
                .map(|frame| frame.id.as_str())
                .collect::<Vec<_>>(),
            ["a1", "b1", "a2", "b2", "a3", "b3"]
        );
    }

    #[test]
    fn fold_interleaved_resolutions_into_two_long_runs() {
        // Dual-monitor desk: capture follows the focused window's display.
        let frames: Vec<_> = (0..60)
            .map(|index| {
                let mut frame = candidate(
                    &format!("m{index}"),
                    i64::from(index) * 10_000,
                    "Chrome",
                    "chrome",
                );
                if index % 2 == 0 {
                    frame.width = 3456;
                    frame.height = 2234;
                } else {
                    frame.width = 3840;
                    frame.height = 2160;
                }
                frame
            })
            .collect();
        let runs = fold_pack_runs(&frames, 30);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].len(), 30);
        assert_eq!(runs[1].len(), 30);
        assert!(runs[0].iter().all(|frame| frame.width == 3456));
        assert!(runs[1].iter().all(|frame| frame.width == 3840));
        assert_eq!(
            first_packable_run(runs.clone())
                .expect("both runs packable")
                .len(),
            30
        );
    }

    #[test]
    fn fold_does_not_idle_cut_when_the_other_resolution_fills_the_gap() {
        let mut laptop = candidate("lap0", 0, "Code", "code");
        laptop.width = 3456;
        laptop.height = 2234;
        let mut desk: Vec<_> = (1..=4)
            .map(|index| {
                let mut frame = candidate(
                    &format!("desk{index}"),
                    i64::from(index) * 10_000,
                    "Chrome",
                    "chrome",
                );
                frame.width = 3840;
                frame.height = 2160;
                frame
            })
            .collect();
        let mut laptop_back = candidate("lap1", 50_000, "Code", "code");
        laptop_back.width = 3456;
        laptop_back.height = 2234;
        let mut frames = vec![laptop];
        frames.append(&mut desk);
        frames.push(laptop_back);
        let runs = fold_pack_runs(&frames, 30);
        assert_eq!(runs.len(), 2);
        let laptop_run = runs
            .iter()
            .find(|run| run.first().is_some_and(|frame| frame.width == 3456))
            .expect("laptop run");
        assert_eq!(
            laptop_run
                .iter()
                .map(|frame| frame.id.as_str())
                .collect::<Vec<_>>(),
            ["lap0", "lap1"]
        );
    }

    #[test]
    fn first_packable_run_skips_short_islands() {
        let mut frames = vec![{
            let mut alone = candidate("alone", 0, "Code", "code");
            alone.width = 3456;
            alone.height = 2234;
            alone
        }];
        frames.extend((0..MIN_PACK_FRAMES).map(|index| {
            candidate(
                &format!("chrome-{index}"),
                10_000 + i64::try_from(index).unwrap_or(0) * 10_000,
                "Chrome",
                "chrome",
            )
        }));
        let runs = fold_pack_runs(&frames, 30);
        let packable = first_packable_run(runs).expect("chrome run");
        assert_eq!(packable.len(), MIN_PACK_FRAMES);
        assert!(packable.iter().all(|frame| frame.id.starts_with("chrome-")));
        assert_eq!(packable_frame_count(&frames, 30), MIN_PACK_FRAMES);
    }

    #[test]
    fn packable_frame_count_ignores_a_lone_resolution() {
        let mut alone = candidate("alone", 0, "Code", "code");
        alone.width = 3456;
        alone.height = 2234;
        assert_eq!(packable_frame_count(&[alone], 30), 0);
    }

    #[test]
    fn merge_group_fills_to_thirty_without_crossing_resolution_streams() {
        let first = segment("a", 12, 0, 100);
        let mut other_display = segment("other", 30, 10_000, 100);
        other_display.width = 96;
        let second = segment("b", 8, first.ended_at_ms + 10_000, 100);
        let third = segment("c", 10, second.ended_at_ms + 10_000, 100);
        let group =
            first_mergeable_gop_group(&[first, other_display, second, third], MIN_PACK_FRAMES)
                .expect("compatible GOPs");
        assert_eq!(
            group
                .iter()
                .map(|segment| segment.id.as_str())
                .collect::<Vec<_>>(),
            ["a", "b", "c"]
        );
        assert_eq!(
            group
                .iter()
                .map(|segment| usize::from(segment.frame_count))
                .sum::<usize>(),
            MIN_PACK_FRAMES
        );
    }

    #[test]
    fn merge_group_normalizes_quality_without_crossing_idle_boundaries() {
        let first = segment("a", 10, 0, 100);
        let different_quality = segment("b", 10, first.ended_at_ms + 10_000, 140);
        let after_quality = segment("c", 10, different_quality.ended_at_ms + 10_000, 100);
        let after_idle = segment("d", 10, after_quality.ended_at_ms + IDLE_GAP_MS + 1, 100);
        let group = first_mergeable_gop_group(
            &[first, different_quality, after_quality, after_idle],
            MIN_PACK_FRAMES,
        );
        assert_eq!(
            group
                .unwrap()
                .iter()
                .map(|segment| segment.id.as_str())
                .collect::<Vec<_>>(),
            ["a", "b", "c"]
        );
    }
}
