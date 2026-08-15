//! Background cold-GOP packer. Hot stills stay JPEG; packed frames drop unpinned JPEGs.

use afterray_codec::{
    Av1Encoder, CONTENT_TYPE_IVF_AV01, DEFAULT_KEYINT, DEFAULT_THUMBNAIL_MAX_EDGE, EncodedGop,
    GopFrameInput, Rav1eEncoder, jpeg_to_i420, parse_ivf, slice_ivf, still_thumbnail,
};
use afterray_protocol::{ArtifactPayload, GopReadMode};
use afterray_store::{
    GopCommitFrame, GopCommitRequest, PackCandidate, PackPolicy, StoreError, Vault, fold_pack_runs,
};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

#[derive(Debug, Clone)]
pub struct GopPackerConfig {
    pub archive: bool,
    pub require_ac: bool,
    pub policy: PackPolicy,
}

impl GopPackerConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let keyint = std::env::var("AFTERRAY_GOP_KEYINT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(DEFAULT_KEYINT);
        let keyint = if matches!(keyint, 6 | 12 | 20 | 24 | 30) {
            keyint
        } else {
            DEFAULT_KEYINT
        };
        let hot_window_seconds = std::env::var("AFTERRAY_GOP_HOT_WINDOW_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(7_200_u64)
            .clamp(3_600, 7_200);
        Self {
            archive: env_flag("AFTERRAY_GOP_ARCHIVE", true),
            require_ac: env_flag("AFTERRAY_GOP_REQUIRE_AC", false),
            policy: PackPolicy {
                hot_window_ms: i64::try_from(hot_window_seconds.saturating_mul(1000))
                    .unwrap_or(7_200_000),
                hot_min_stills: std::env::var("AFTERRAY_GOP_HOT_MIN_STILLS")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(360),
                ocr_grace_ms: i64::from(
                    std::env::var("AFTERRAY_GOP_OCR_GRACE_SECONDS")
                        .ok()
                        .and_then(|value| value.parse().ok())
                        .unwrap_or(600_u32),
                ) * 1000,
                keyint,
            },
        }
    }
}

fn env_flag(name: &str, default: bool) -> bool {
    std::env::var(name)
        .ok()
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes"))
        .unwrap_or(default)
}

/// Yield to capture: startup (no frame yet), an in-flight screenshot, or
/// the 2s window before the next heartbeat.
#[must_use]
pub fn should_yield_to_capture(
    capture_busy: bool,
    recording: bool,
    last_capture_ms: i64,
    now_ms: i64,
    interval_ms: i64,
) -> bool {
    if capture_busy {
        return true;
    }
    if !recording {
        return false;
    }
    // Shim is still coming up. rav1e must not starve SCShareableContent.
    if last_capture_ms <= 0 {
        return true;
    }
    if interval_ms <= 0 {
        return false;
    }
    let next = last_capture_ms.saturating_add(interval_ms);
    next.saturating_sub(now_ms) < 2_000
}

pub struct GopPacker {
    pub config: GopPackerConfig,
    encode_busy: AtomicBool,
}

impl GopPacker {
    #[must_use]
    pub fn new(config: GopPackerConfig) -> Self {
        Self {
            config,
            encode_busy: AtomicBool::new(false),
        }
    }

    #[must_use]
    pub fn encode_busy(&self) -> bool {
        self.encode_busy.load(Ordering::SeqCst)
    }

    pub fn pack_one(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        if !self.config.archive {
            return Ok(None);
        }
        if self.config.require_ac && !afterray_platform_macos::on_ac_power() {
            return Ok(None);
        }
        if self
            .encode_busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(None);
        }
        let result = self.pack_one_inner(vault, now_ms);
        self.encode_busy.store(false, Ordering::SeqCst);
        result
    }

    fn pack_one_inner(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        let candidates = vault.list_pack_candidates(now_ms, &self.config.policy)?;
        let runs = fold_pack_runs(&candidates, self.config.policy.keyint);
        let Some(run) = runs.into_iter().next() else {
            return Ok(None);
        };
        let moment_ids: Vec<String> = run.iter().map(|frame| frame.id.clone()).collect();
        let payload = json!({
            "moment_ids": moment_ids,
            "keyint": self.config.policy.keyint,
            "encoder": "rav1e",
        });
        let job_id = vault.insert_pack_job(now_ms, &payload.to_string())?;
        match encode_run(vault, &run) {
            Ok(encoded) => {
                let frames: Vec<GopCommitFrame> = encoded
                    .frames
                    .iter()
                    .map(|frame| GopCommitFrame {
                        index: frame.index,
                        is_keyframe: frame.is_keyframe,
                        byte_offset: frame.byte_offset,
                        byte_length: frame.byte_length,
                        content_hash: frame.content_hash,
                    })
                    .collect();
                let content_hash = hash_hex(blake3::hash(&encoded.ivf).as_bytes());
                let started_at_ms = run.first().map(|frame| frame.captured_at_ms).unwrap_or(0);
                let ended_at_ms = run
                    .last()
                    .map(|frame| frame.captured_at_ms)
                    .unwrap_or(started_at_ms);
                match vault.commit_gop(GopCommitRequest {
                    moment_ids: &moment_ids,
                    ivf: &encoded.ivf,
                    codec: encoded.codec,
                    encoder: &encoded.encoder,
                    encoder_version: &encoded.encoder_version,
                    width: encoded.width,
                    height: encoded.height,
                    keyint: encoded.keyint,
                    started_at_ms,
                    ended_at_ms,
                    content_hash: &content_hash,
                    frames: &frames,
                }) {
                    Ok(segment_id) => {
                        if let Err(error) = verify_gop(vault, &segment_id, &encoded) {
                            if let Err(abort_error) = vault.abort_gop(&segment_id) {
                                eprintln!(
                                    "gop packer: abort after verify fail for {segment_id}: {abort_error}"
                                );
                            }
                            let _ = vault.finish_pack_job(
                                &job_id,
                                now_ms,
                                None,
                                Some(&error.to_string()),
                            );
                            return Err(error);
                        }
                        vault.mark_gop_ready(&segment_id)?;
                        vault.finish_pack_job(&job_id, now_ms, Some(&segment_id), None)?;
                        if let Err(error) = vault.drop_unpinned_stills(&segment_id) {
                            eprintln!("gop packer: drop stills failed for {segment_id}: {error}");
                        }
                        Ok(Some(segment_id))
                    }
                    Err(StoreError::GopStale) => {
                        vault.finish_pack_job(
                            &job_id,
                            now_ms,
                            None,
                            Some("retention raced the commit"),
                        )?;
                        Ok(None)
                    }
                    Err(error) => {
                        vault.finish_pack_job(&job_id, now_ms, None, Some(&error.to_string()))?;
                        Err(error.into())
                    }
                }
            }
            Err(error) => {
                vault.finish_pack_job(&job_id, now_ms, None, Some(&error.to_string()))?;
                Err(error)
            }
        }
    }
}

fn encode_run(vault: &Vault, run: &[PackCandidate]) -> Result<EncodedGop, anyhow::Error> {
    let mut planes = Vec::with_capacity(run.len());
    let mut inputs = Vec::with_capacity(run.len());
    for frame in run {
        let still = vault.read_artifact(&frame.image_artifact_id)?;
        // Thumbnail now, while the JPEG is decrypted and in hand. Once this run
        // commits, `drop_unpinned_stills` deletes it — and nothing on this side
        // can decode AV1 to get the pixels back.
        if let Err(error) = ensure_thumbnail(vault, &frame.id, &still.bytes) {
            eprintln!(
                "gop packer: thumbnail failed for moment {}: {error}",
                frame.id
            );
        }
        let (width, height, yuv) = jpeg_to_i420(&still.bytes)?;
        let even_width = frame.width & !1;
        let even_height = frame.height & !1;
        if width != even_width || height != even_height {
            anyhow::bail!(
                "decoded {}x{} but stored size was {}x{}",
                width,
                height,
                frame.width,
                frame.height
            );
        }
        planes.push((frame.id.clone(), frame.captured_at_ms, width, height, yuv));
    }
    for plane in &planes {
        inputs.push(GopFrameInput {
            moment_id: plane.0.as_str(),
            captured_at_ms: plane.1,
            width: plane.2,
            height: plane.3,
            yuv: plane.4.as_slice(),
        });
    }
    let started = Instant::now();
    let encoded = Rav1eEncoder::default().encode_closed_gop(&inputs)?;
    eprintln!(
        "gop pack: {} frames {}x{} in {:.1}s ({:.0} ms/frame)",
        encoded.frames.len(),
        encoded.width,
        encoded.height,
        started.elapsed().as_secs_f32(),
        started.elapsed().as_secs_f32() * 1000.0 / encoded.frames.len() as f32
    );
    Ok(encoded)
}

fn ensure_thumbnail(vault: &Vault, moment_id: &str, jpeg: &[u8]) -> Result<(), anyhow::Error> {
    if vault.thumbnail_artifact_id(moment_id)?.is_some() {
        return Ok(());
    }
    let bytes = still_thumbnail(jpeg, DEFAULT_THUMBNAIL_MAX_EDGE)?;
    vault.set_thumbnail(moment_id, &bytes)?;
    Ok(())
}

fn verify_gop(vault: &Vault, segment_id: &str, encoded: &EncodedGop) -> Result<(), anyhow::Error> {
    let payload = vault.read_gop_artifact_writing(segment_id)?;
    let parsed = parse_ivf(&payload.bytes)?;
    if !payload.bytes.starts_with(afterray_codec::IVF_MAGIC) {
        anyhow::bail!("packed GOP is not IVF");
    }
    if parsed.frames.is_empty() {
        anyhow::bail!("packed GOP has no frames");
    }
    let expected = encoded.frames[0].content_hash;
    let actual = *blake3::hash(&parsed.frames[0].data).as_bytes();
    if expected != actual {
        anyhow::bail!("packed GOP keyframe hash mismatch");
    }
    Ok(())
}

pub fn read_gop_frame(
    vault: &Vault,
    segment_id: &str,
    index: u16,
    mode: GopReadMode,
) -> Result<ArtifactPayload, StoreError> {
    let frames = vault.live_gop_frames(segment_id)?;
    if !frames.iter().any(|frame| frame.index == index) {
        return Err(StoreError::GopNotFound(format!("{segment_id}#{index}")));
    }
    let payload = vault.read_gop_artifact(segment_id)?;
    let last = match mode {
        GopReadMode::Poster => 0,
        GopReadMode::Exact => usize::from(index),
    };
    let sliced = slice_ivf(&payload.bytes, last).map_err(|_| StoreError::Crypto)?;
    Ok(ArtifactPayload {
        id: payload.id.clone(),
        content_type: CONTENT_TYPE_IVF_AV01.to_owned(),
        bytes: sliced,
    })
}

fn hash_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::should_yield_to_capture;

    #[test]
    fn yields_while_capture_is_busy() {
        assert!(should_yield_to_capture(true, true, 0, 10_000, 10_000));
    }

    #[test]
    fn yields_inside_two_second_heartbeat_window() {
        // last capture at t=0, interval 10s → next heartbeat at 10_000.
        assert!(should_yield_to_capture(false, true, 1, 8_500, 10_000));
        assert!(should_yield_to_capture(false, true, 1, 9_500, 10_000));
        assert!(!should_yield_to_capture(false, true, 1, 7_000, 10_000));
    }

    #[test]
    fn ignores_heartbeat_when_not_recording() {
        assert!(!should_yield_to_capture(false, false, 1, 9_500, 10_000));
        assert!(!should_yield_to_capture(false, false, 0, 9_500, 10_000));
    }

    #[test]
    fn yields_until_the_first_capture_while_recording() {
        assert!(should_yield_to_capture(false, true, 0, 9_500, 10_000));
    }
}
