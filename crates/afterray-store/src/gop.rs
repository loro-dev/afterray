//! Closed-GOP pack candidates, commit, and startup rollback.

use crate::{StoreError, Vault};
use afterray_protocol::{GopFrameView, GopSegmentView};
use rusqlite::{OptionalExtension, params};
use serde::Serialize;
use uuid::Uuid;

pub const IDLE_GAP_MS: i64 = 30_000;

#[derive(Debug, Clone, PartialEq, Eq)]
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
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub status: String,
}

#[derive(Debug, Clone)]
pub struct GopFrameRow {
    pub index: u16,
    pub moment_id: String,
    pub is_keyframe: bool,
    pub byte_offset: u32,
    pub byte_length: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct GopPackJob {
    pub id: String,
    pub state: String,
    pub created_at_ms: i64,
    pub error: Option<String>,
}

/// Fold pack candidates into closed-GOP runs.
///
/// Walk wall-clock order and close a run on idle gap, resolution change, or
/// `keyint`. App switches stay in the same GOP so A↔B flicker does not
/// collapse into one-frame stills.
#[must_use]
pub fn fold_pack_runs(candidates: &[PackCandidate], keyint: u16) -> Vec<Vec<PackCandidate>> {
    let keyint = usize::from(keyint.max(1));
    let mut runs = Vec::new();
    let mut current: Vec<PackCandidate> = Vec::new();
    for candidate in candidates {
        if let Some(previous) = current.last() {
            let idle = candidate
                .captured_at_ms
                .saturating_sub(previous.captured_at_ms)
                > IDLE_GAP_MS;
            let size_changed =
                candidate.width != previous.width || candidate.height != previous.height;
            if idle || size_changed {
                runs.push(std::mem::take(&mut current));
            }
        }
        current.push(candidate.clone());
        if current.len() >= keyint {
            runs.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        runs.push(current);
    }
    runs
}

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
        let connection = self.connection.lock().unwrap();
        let cutoff = now_ms.saturating_sub(policy.hot_window_ms);
        let ocr_cutoff = now_ms.saturating_sub(policy.ocr_grace_ms);
        let floor = i64::try_from(policy.hot_min_stills).unwrap_or(i64::MAX);
        let mut statement = connection.prepare(
            "SELECT m.id, m.captured_at_ms, m.image_artifact_id,
                    m.bundle_identifier, m.application_name, m.width, m.height
               FROM moments m
              WHERE m.gop_segment_id IS NULL
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
                )
              ORDER BY m.captured_at_ms ASC, m.id ASC",
        )?;
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

    pub fn pack_status_counts(&self) -> Result<(u64, u64, u64, u64), StoreError> {
        let connection = self.readers.get();
        let running = count_where(&connection, "gop_pack_jobs", "state = 'running'")?;
        let done = count_where(&connection, "gop_pack_jobs", "state = 'done'")?;
        let failed = count_where(&connection, "gop_pack_jobs", "state = 'failed'")?;
        let ready = count_where(&connection, "gop_segments", "status = 'ready'")?;
        Ok((running, done, failed, ready))
    }

    pub fn commit_gop(&self, request: GopCommitRequest<'_>) -> Result<String, StoreError> {
        if request.moment_ids.is_empty() || request.frames.len() != request.moment_ids.len() {
            return Err(StoreError::GopStale);
        }
        let _artifact_guard = self.artifact_io.write().unwrap();
        let staged = self.stage_artifact_unlocked("video/x-ivf; codec=av01", request.ivf)?;
        let segment_id = Uuid::now_v7().to_string();
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
                     status, content_hash
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'writing', ?12)",
                params![
                    segment_id,
                    staged.id,
                    request.codec,
                    request.encoder,
                    request.encoder_version,
                    i64::from(request.width),
                    i64::from(request.height),
                    request.frames.len() as i64,
                    i64::from(request.keyint),
                    request.started_at_ms,
                    request.ended_at_ms,
                    request.content_hash,
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
                claimed += transaction.execute(
                    "UPDATE moments
                        SET gop_segment_id = ?1, gop_index = ?2
                      WHERE id = ?3 AND gop_segment_id IS NULL",
                    params![segment_id, index as i64, moment_id],
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
                        frame_count, keyint, started_at_ms, ended_at_ms, status
                   FROM gop_segments WHERE id = ?1 AND status = ?2",
                params![segment_id, status],
                |row| {
                    Ok(GopSegmentRecord {
                        id: row.get(0)?,
                        artifact_id: row.get(1)?,
                        codec: row.get(2)?,
                        encoder: row.get(3)?,
                        width: u32::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
                        height: u32::try_from(row.get::<_, i64>(5)?).unwrap_or(0),
                        frame_count: u16::try_from(row.get::<_, i64>(6)?).unwrap_or(0),
                        keyint: u16::try_from(row.get::<_, i64>(7)?).unwrap_or(0),
                        started_at_ms: row.get(8)?,
                        ended_at_ms: row.get(9)?,
                        status: row.get(10)?,
                    })
                },
            )
            .optional()?
            .ok_or_else(|| StoreError::GopNotFound(segment_id.to_owned()))
    }

    pub fn live_gop_frames(&self, segment_id: &str) -> Result<Vec<GopFrameRow>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT frame_index, moment_id, is_keyframe, byte_offset, byte_length
               FROM gop_frames WHERE segment_id = ?1 ORDER BY frame_index",
        )?;
        let rows = statement.query_map([segment_id], |row| {
            Ok(GopFrameRow {
                index: u16::try_from(row.get::<_, i64>(0)?).unwrap_or(0),
                moment_id: row.get(1)?,
                is_keyframe: row.get::<_, i64>(2)? != 0,
                byte_offset: u32::try_from(row.get::<_, i64>(3)?).unwrap_or(0),
                byte_length: u32::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
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
}
