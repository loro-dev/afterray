//! Background cold-GOP packer. Hot stills stay JPEG; packed frames drop unpinned JPEGs.

use afterray_codec::{
    Av1Encoder, CONTENT_TYPE_IVF_AV01, DEFAULT_KEYINT, DEFAULT_THUMBNAIL_MAX_EDGE, EncodedGop,
    GopFrameInput, Rav1eEncoder, i420_len, jpeg_to_i420, parse_ivf, slice_ivf, still_thumbnail,
};
use afterray_protocol::{ArtifactPayload, GopQualityPreviewSummary, GopReadMode};
use afterray_store::{
    GopCommitFrame, GopCommitRequest, GopMergeRequest, GopRewriteRequest, MIN_PACK_FRAMES,
    PackCandidate, PackPolicy, StoreError, Vault, first_packable_run, fold_pack_runs,
};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct GopPackerConfig {
    pub archive: bool,
    pub policy: PackPolicy,
}

impl GopPackerConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let keyint = std::env::var("AFTERRAY_GOP_KEYINT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(DEFAULT_KEYINT);
        let keyint = if keyint == DEFAULT_KEYINT {
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
    quality_aging: AtomicBool,
    worst_quantizer: AtomicU16,
}

impl GopPacker {
    #[must_use]
    pub fn new(config: GopPackerConfig) -> Self {
        Self {
            config,
            encode_busy: AtomicBool::new(false),
            quality_aging: AtomicBool::new(false),
            worst_quantizer: AtomicU16::new(180),
        }
    }

    pub fn set_quality_policy(&self, enabled: bool, worst_quantizer: u16) {
        self.quality_aging.store(enabled, Ordering::Relaxed);
        self.worst_quantizer
            .store(worst_quantizer.clamp(120, 240), Ordering::Relaxed);
    }

    #[must_use]
    pub fn quality_aging(&self) -> bool {
        self.quality_aging.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn worst_quantizer(&self) -> u16 {
        self.worst_quantizer.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn quantizer_for_age_ms(&self, age_ms: i64) -> usize {
        quality_quantizer(age_ms, self.quality_aging(), self.worst_quantizer())
    }

    #[must_use]
    pub fn encode_busy(&self) -> bool {
        self.encode_busy.load(Ordering::SeqCst)
    }

    /// Packs one run of cold stills, or `Ok(None)` when there is nothing to pack.
    ///
    /// Deliberately holds **no power policy of its own**. It used to re-check AC
    /// as a "backstop", which meant a user pressing "run now" on Archive while
    /// on battery got `Ok(None)` — indistinguishable from an empty backlog, so
    /// the caller cancelled its own override and logged "nothing left to pack".
    /// One gate, in `compute::ComputeGovernor`, which can see the override.
    pub fn pack_one(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        if !self.config.archive {
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
        // Short "GOPs" spend too much on keyframes and encrypted-file
        // metadata: leave the JPEG until thirty compatible frames are cold.
        let Some(run) = first_packable_run(runs) else {
            if let Some(segment_id) = self.merge_one_inner(vault, now_ms)? {
                return Ok(Some(segment_id));
            }
            return self.reencode_one_inner(vault, now_ms);
        };
        let newest_at_ms = run.last().map_or(now_ms, |frame| frame.captured_at_ms);
        let quantizer = self.quantizer_for_age_ms(now_ms.saturating_sub(newest_at_ms));
        let moment_ids: Vec<String> = run.iter().map(|frame| frame.id.clone()).collect();
        let payload = json!({
            "moment_ids": moment_ids,
            "keyint": self.config.policy.keyint,
            "encoder": "rav1e",
            "quantizer": quantizer,
        });
        let job_id = vault.insert_pack_job(now_ms, &payload.to_string())?;
        match encode_run(vault, &run, quantizer) {
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
                    quality_quantizer: u16::try_from(quantizer).unwrap_or(u16::MAX),
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

    #[allow(clippy::too_many_lines)]
    fn merge_one_inner(&self, vault: &Vault, now_ms: i64) -> Result<Option<String>, anyhow::Error> {
        let Some(segments) = vault.next_gop_merge_candidate()? else {
            return Ok(None);
        };
        let newest_at_ms = segments
            .last()
            .map_or(now_ms, |segment| segment.ended_at_ms);
        let age_quantizer =
            u16::try_from(self.quantizer_for_age_ms(now_ms.saturating_sub(newest_at_ms)))
                .unwrap_or(u16::MAX);
        let quantizer = segments
            .iter()
            .map(|segment| segment.quality_quantizer)
            .max()
            .unwrap_or(BASE_QUANTIZER)
            .max(age_quantizer);
        let expected_frames = segments
            .iter()
            .map(|segment| usize::from(segment.frame_count))
            .sum::<usize>();
        if expected_frames > MIN_PACK_FRAMES {
            anyhow::bail!(
                "GOP merge candidate has {expected_frames} frames, maximum is {MIN_PACK_FRAMES}"
            );
        }

        let mut sources = Vec::with_capacity(segments.len());
        let mut source_bytes = 0_usize;
        for segment in &segments {
            let rows = vault.live_gop_frames(&segment.id)?;
            let source = vault.read_gop_artifact(&segment.id)?;
            source_bytes = source_bytes.saturating_add(source.bytes.len());
            let decoded = decode_gop_with_helper(&source.bytes)?;
            if decoded.width != segment.width
                || decoded.height != segment.height
                || decoded.frames.len() != rows.len()
                || rows.len() != usize::from(segment.frame_count)
            {
                anyhow::bail!(
                    "decoded GOP {} changed shape: {}x{} / {} frames, expected {}x{} / {}",
                    segment.id,
                    decoded.width,
                    decoded.height,
                    decoded.frames.len(),
                    segment.width,
                    segment.height,
                    segment.frame_count
                );
            }
            sources.push((rows, decoded));
        }

        let mut inputs = Vec::with_capacity(expected_frames);
        let mut moment_ids = Vec::with_capacity(expected_frames);
        for (rows, decoded) in &sources {
            for (row, frame) in rows.iter().zip(decoded.frames.iter()) {
                moment_ids.push(row.moment_id.clone());
                inputs.push(GopFrameInput {
                    moment_id: row.moment_id.as_str(),
                    captured_at_ms: row.captured_at_ms,
                    width: decoded.width,
                    height: decoded.height,
                    yuv: frame.as_slice(),
                });
            }
        }
        let started = Instant::now();
        let encoded = Rav1eEncoder {
            quantizer: usize::from(quantizer),
            ..Rav1eEncoder::default()
        }
        .encode_closed_gop(&inputs)?;
        let parsed = parse_ivf(&encoded.ivf)?;
        if parsed.frames.len() != expected_frames {
            anyhow::bail!("merged GOP lost frames");
        }
        let commit_frames = encoded
            .frames
            .iter()
            .map(|frame| GopCommitFrame {
                index: frame.index,
                is_keyframe: frame.is_keyframe,
                byte_offset: frame.byte_offset,
                byte_length: frame.byte_length,
                content_hash: frame.content_hash,
            })
            .collect::<Vec<_>>();
        let content_hash = hash_hex(blake3::hash(&encoded.ivf).as_bytes());
        let merged_id = match vault.merge_gops(GopMergeRequest {
            source_segments: &segments,
            moment_ids: &moment_ids,
            ivf: &encoded.ivf,
            codec: encoded.codec,
            encoder: &encoded.encoder,
            encoder_version: &encoded.encoder_version,
            width: encoded.width,
            height: encoded.height,
            keyint: encoded.keyint,
            quality_quantizer: quantizer,
            started_at_ms: segments[0].started_at_ms,
            ended_at_ms: segments.last().map_or(0, |segment| segment.ended_at_ms),
            content_hash: &content_hash,
            frames: &commit_frames,
        }) {
            Ok(segment_id) => segment_id,
            Err(StoreError::GopStale) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        eprintln!(
            "gop compact: merged {} segments / {} frames into {} in {:.1}s ({}→{} bytes)",
            segments.len(),
            expected_frames,
            merged_id,
            started.elapsed().as_secs_f32(),
            source_bytes,
            encoded.ivf.len()
        );
        Ok(Some(merged_id))
    }

    fn reencode_one_inner(
        &self,
        vault: &Vault,
        now_ms: i64,
    ) -> Result<Option<String>, anyhow::Error> {
        if !self.quality_aging() {
            return Ok(None);
        }
        let worst = self.worst_quantizer();
        let (first, second) = intermediate_quantizers(worst);
        let Some(segment) = vault.next_gop_quality_candidate(now_ms, first, second, worst)? else {
            return Ok(None);
        };
        let rows = vault.live_gop_frames(&segment.id)?;
        let source = vault.read_gop_artifact(&segment.id)?;
        let decoded = decode_gop_with_helper(&source.bytes)?;
        if decoded.width != segment.width
            || decoded.height != segment.height
            || decoded.frames.len() != rows.len()
        {
            anyhow::bail!(
                "decoded GOP {} changed shape: {}x{} / {} frames, expected {}x{} / {}",
                segment.id,
                decoded.width,
                decoded.height,
                decoded.frames.len(),
                segment.width,
                segment.height,
                rows.len()
            );
        }
        let target = self.quantizer_for_age_ms(now_ms.saturating_sub(segment.ended_at_ms));
        let inputs = rows
            .iter()
            .zip(decoded.frames.iter())
            .map(|(row, frame)| GopFrameInput {
                moment_id: row.moment_id.as_str(),
                captured_at_ms: row.captured_at_ms,
                width: decoded.width,
                height: decoded.height,
                yuv: frame.as_slice(),
            })
            .collect::<Vec<_>>();
        let started = Instant::now();
        let encoded = Rav1eEncoder {
            quantizer: target,
            ..Rav1eEncoder::default()
        }
        .encode_closed_gop(&inputs)?;
        let parsed = parse_ivf(&encoded.ivf)?;
        if parsed.frames.len() != rows.len() {
            anyhow::bail!("rewritten GOP {} lost frames", segment.id);
        }
        let commit_frames = encoded
            .frames
            .iter()
            .map(|frame| GopCommitFrame {
                index: frame.index,
                is_keyframe: frame.is_keyframe,
                byte_offset: frame.byte_offset,
                byte_length: frame.byte_length,
                content_hash: frame.content_hash,
            })
            .collect::<Vec<_>>();
        let moment_ids = rows
            .iter()
            .map(|row| row.moment_id.clone())
            .collect::<Vec<_>>();
        let content_hash = hash_hex(blake3::hash(&encoded.ivf).as_bytes());
        vault.rewrite_gop(GopRewriteRequest {
            segment_id: &segment.id,
            moment_ids: &moment_ids,
            ivf: &encoded.ivf,
            encoder: &encoded.encoder,
            encoder_version: &encoded.encoder_version,
            quality_quantizer: u16::try_from(target).unwrap_or(u16::MAX),
            content_hash: &content_hash,
            frames: &commit_frames,
        })?;
        eprintln!(
            "gop quality: rewrote {} q{}→q{} in {:.1}s ({}→{} bytes)",
            segment.id,
            segment.quality_quantizer,
            target,
            started.elapsed().as_secs_f32(),
            source.bytes.len(),
            encoded.ivf.len()
        );
        Ok(Some(segment.id))
    }
}

struct DecodedGop {
    width: u32,
    height: u32,
    frames: Vec<Vec<u8>>,
}

impl Drop for DecodedGop {
    fn drop(&mut self) {
        for frame in &mut self.frames {
            frame.fill(0);
        }
    }
}

const GOP_DECODER_TIMEOUT: Duration = Duration::from_secs(30);
const MAXIMUM_DECODED_DIMENSION: u32 = 8_192;
const MAXIMUM_DECODED_GOP_BYTES: usize = 1_610_612_736;
const MAXIMUM_DECODER_STDERR_BYTES: usize = 64 * 1024;

fn decode_gop_with_helper(ivf: &[u8]) -> Result<DecodedGop, anyhow::Error> {
    let parsed = parse_ivf(ivf)?;
    let width = u32::from(parsed.width);
    let height = u32::from(parsed.height);
    let frame_count = parsed.frames.len();
    let maximum_output_bytes = decoder_output_length(width, height, frame_count)?;
    if width > MAXIMUM_DECODED_DIMENSION
        || height > MAXIMUM_DECODED_DIMENSION
        || maximum_output_bytes > MAXIMUM_DECODED_GOP_BYTES
    {
        anyhow::bail!(
            "GOP decode shape {width}x{height} / {frame_count} frames exceeds the maintenance limit"
        );
    }
    let path = gop_decoder_path().ok_or_else(|| {
        anyhow::anyhow!(
            "afterray-gop-decoder not found; set AFTERRAY_GOP_DECODER or rebuild the app"
        )
    })?;
    let mut child = Command::new(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| anyhow::anyhow!("launch {}: {error}", path.display()))?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow::anyhow!("decoder stdin unavailable"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("decoder stdout unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| anyhow::anyhow!("decoder stderr unavailable"))?;
    let input = ivf.to_vec();
    let writer = std::thread::spawn(move || {
        let mut stdin = stdin;
        stdin.write_all(&input).map_err(anyhow::Error::from)
    });
    let reader = std::thread::spawn(move || read_decoder_output(stdout, maximum_output_bytes));
    let stderr_reader =
        std::thread::spawn(move || read_capped(stderr, MAXIMUM_DECODER_STDERR_BYTES));

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() >= GOP_DECODER_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            let _ = writer.join();
            let _ = reader.join();
            let _ = stderr_reader.join();
            anyhow::bail!(
                "{} exceeded the {} second decode deadline",
                path.display(),
                GOP_DECODER_TIMEOUT.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let write_result = writer
        .join()
        .map_err(|_| anyhow::anyhow!("decoder stdin worker panicked"))?;
    let decoded = reader
        .join()
        .map_err(|_| anyhow::anyhow!("decoder stdout worker panicked"))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("decoder stderr worker panicked"))??;
    if !status.success() {
        let stderr = String::from_utf8_lossy(&stderr);
        anyhow::bail!("{} exited {}: {}", path.display(), status, stderr.trim());
    }
    write_result?;
    decoded
}

fn gop_decoder_path() -> Option<PathBuf> {
    let configured = std::env::var_os("AFTERRAY_GOP_DECODER")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    let sibling = std::env::current_exe().ok().and_then(|path| {
        path.parent()
            .map(|parent| parent.join("afterray-gop-decoder"))
    });
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    configured
        .into_iter()
        .chain(sibling)
        .chain([
            repo.join(".build/release/afterray-gop-decoder"),
            repo.join(".build/debug/afterray-gop-decoder"),
        ])
        .find(|path| path.is_file())
}

fn decoder_output_length(
    width: u32,
    height: u32,
    frame_count: usize,
) -> Result<usize, anyhow::Error> {
    let frame_length = i420_len(width, height);
    20_usize
        .checked_add(
            frame_count
                .checked_mul(frame_length.saturating_add(4))
                .ok_or_else(|| anyhow::anyhow!("AV1 decoder output length overflow"))?,
        )
        .ok_or_else(|| anyhow::anyhow!("AV1 decoder output length overflow"))
}

fn read_capped(
    mut reader: impl std::io::Read,
    maximum_bytes: usize,
) -> Result<Vec<u8>, anyhow::Error> {
    let mut bytes = Vec::new();
    let mut exceeded = false;
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        let remaining = maximum_bytes.saturating_sub(bytes.len());
        bytes.extend_from_slice(&buffer[..count.min(remaining)]);
        exceeded |= count > remaining;
    }
    if exceeded {
        anyhow::bail!("decoder diagnostic output exceeded {maximum_bytes} bytes");
    }
    Ok(bytes)
}

#[cfg(test)]
fn parse_decoder_output(bytes: &[u8]) -> Result<DecodedGop, anyhow::Error> {
    read_decoder_output(std::io::Cursor::new(bytes), MAXIMUM_DECODED_GOP_BYTES)
}

fn read_decoder_output(
    mut reader: impl std::io::Read,
    maximum_bytes: usize,
) -> Result<DecodedGop, anyhow::Error> {
    const MAGIC: &[u8; 8] = b"ARYI4201";
    const MAXIMUM_FRAMES: usize = 30;
    let mut header = [0_u8; 20];
    reader.read_exact(&mut header)?;
    if &header[..8] != MAGIC {
        anyhow::bail!("AV1 decoder returned an invalid header");
    }
    let width = read_u32_le(&header, 8)?;
    let height = read_u32_le(&header, 12)?;
    let frame_count = usize::try_from(read_u32_le(&header, 16)?).unwrap_or(usize::MAX);
    if width < 16
        || height < 16
        || !width.is_multiple_of(2)
        || !height.is_multiple_of(2)
        || frame_count == 0
        || width > MAXIMUM_DECODED_DIMENSION
        || height > MAXIMUM_DECODED_DIMENSION
        || frame_count > MAXIMUM_FRAMES
    {
        anyhow::bail!("AV1 decoder returned invalid dimensions or frame count");
    }
    let expected_frame_len = i420_len(width, height);
    let expected_output_len = decoder_output_length(width, height, frame_count)?;
    if expected_output_len > maximum_bytes || expected_output_len > MAXIMUM_DECODED_GOP_BYTES {
        anyhow::bail!("AV1 decoder output exceeds the bounded decode budget");
    }
    let mut frames = Vec::with_capacity(frame_count);
    for _ in 0..frame_count {
        let mut prefix = [0_u8; 4];
        reader.read_exact(&mut prefix)?;
        let length = usize::try_from(read_u32_le(&prefix, 0)?).unwrap_or(usize::MAX);
        if length != expected_frame_len {
            anyhow::bail!("AV1 decoder returned a malformed I420 frame");
        }
        let mut frame = vec![0_u8; length];
        reader.read_exact(&mut frame)?;
        frames.push(frame);
    }
    let mut trailing = [0_u8; 1];
    if reader.read(&mut trailing)? != 0 {
        anyhow::bail!("AV1 decoder returned trailing data");
    }
    Ok(DecodedGop {
        width,
        height,
        frames,
    })
}

fn read_u32_le(bytes: &[u8], offset: usize) -> Result<u32, anyhow::Error> {
    let slice = bytes
        .get(offset..offset.saturating_add(4))
        .ok_or_else(|| anyhow::anyhow!("AV1 decoder output was truncated"))?;
    Ok(u32::from_le_bytes(slice.try_into().unwrap()))
}

fn encode_run(
    vault: &Vault,
    run: &[PackCandidate],
    quantizer: usize,
) -> Result<EncodedGop, anyhow::Error> {
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
    let encoded = Rav1eEncoder {
        quantizer,
        ..Rav1eEncoder::default()
    }
    .encode_closed_gop(&inputs)?;
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

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const BASE_QUANTIZER: u16 = 100;

#[must_use]
pub fn intermediate_quantizers(worst_quantizer: u16) -> (u16, u16) {
    let worst = worst_quantizer.clamp(120, 240);
    let delta = worst.saturating_sub(BASE_QUANTIZER);
    (
        BASE_QUANTIZER.saturating_add(delta / 3),
        BASE_QUANTIZER.saturating_add(delta.saturating_mul(2) / 3),
    )
}

// @dec:tiered-evidence-retention — docs/decisions/active/architecture/2026-08-27-tiered-evidence-retention.md
#[must_use]
pub fn quality_quantizer(age_ms: i64, enabled: bool, worst_quantizer: u16) -> usize {
    if !enabled || age_ms < 7 * DAY_MS {
        return usize::from(BASE_QUANTIZER);
    }
    let worst = worst_quantizer.clamp(120, 240);
    let (first, second) = intermediate_quantizers(worst);
    let quantizer = if age_ms >= 28 * DAY_MS {
        worst
    } else if age_ms >= 14 * DAY_MS {
        second
    } else {
        first
    };
    usize::from(quantizer)
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

pub struct GopQualityPreview {
    pub payload: ArtifactPayload,
    pub summary: GopQualityPreviewSummary,
}

pub fn quality_preview(
    vault: &Vault,
    quantizer: u16,
) -> Result<Option<GopQualityPreview>, anyhow::Error> {
    let quantizer = quantizer.clamp(120, 240);
    let Some((segment, total_gop_bytes, degradable_gop_bytes)) =
        vault.gop_quality_preview_candidate(quantizer)?
    else {
        return Ok(None);
    };
    let source = vault.read_gop_artifact(&segment.id)?;
    let source_byte_length = u64::try_from(source.bytes.len()).unwrap_or(u64::MAX);
    let (poster, preview_byte_length, preview_quantizer) = if segment.quality_quantizer < quantizer
    {
        let rows = vault.live_gop_frames(&segment.id)?;
        let decoded = decode_gop_with_helper(&source.bytes)?;
        if decoded.frames.len() != rows.len()
            || decoded.width != segment.width
            || decoded.height != segment.height
        {
            anyhow::bail!("preview decoder changed GOP shape");
        }
        let inputs = rows
            .iter()
            .zip(decoded.frames.iter())
            .map(|(row, frame)| GopFrameInput {
                moment_id: row.moment_id.as_str(),
                captured_at_ms: row.captured_at_ms,
                width: decoded.width,
                height: decoded.height,
                yuv: frame.as_slice(),
            })
            .collect::<Vec<_>>();
        let encoded = Rav1eEncoder {
            quantizer: usize::from(quantizer),
            ..Rav1eEncoder::default()
        }
        .encode_closed_gop(&inputs)?;
        (
            slice_ivf(&encoded.ivf, 0)?,
            u64::try_from(encoded.ivf.len()).unwrap_or(u64::MAX),
            quantizer,
        )
    } else {
        let poster = read_gop_frame(vault, &segment.id, 0, GopReadMode::Poster)?;
        (
            poster.bytes.clone(),
            source_byte_length,
            segment.quality_quantizer,
        )
    };
    let estimated_degradable = if source_byte_length == 0 {
        degradable_gop_bytes
    } else {
        let value = u128::from(degradable_gop_bytes)
            .saturating_mul(u128::from(preview_byte_length))
            / u128::from(source_byte_length);
        u64::try_from(value).unwrap_or(u64::MAX)
    };
    let estimated = total_gop_bytes
        .saturating_sub(degradable_gop_bytes)
        .saturating_add(estimated_degradable);
    Ok(Some(GopQualityPreview {
        payload: ArtifactPayload {
            id: format!("gop-quality-preview:{}", segment.id),
            content_type: CONTENT_TYPE_IVF_AV01.to_owned(),
            bytes: poster,
        },
        summary: GopQualityPreviewSummary {
            quantizer,
            source_quantizer: segment.quality_quantizer,
            preview_quantizer,
            sampled_at_ms: segment.ended_at_ms,
            source_byte_length,
            preview_byte_length,
            total_gop_byte_length: total_gop_bytes,
            estimated_worst_gop_byte_length: estimated,
        },
    }))
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
    use super::{
        DAY_MS, parse_decoder_output, quality_quantizer, read_decoder_output,
        should_yield_to_capture,
    };

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

    #[test]
    fn quality_ages_through_three_bounded_tiers() {
        assert_eq!(quality_quantizer(7 * DAY_MS - 1, true, 190), 100);
        assert_eq!(quality_quantizer(7 * DAY_MS, true, 190), 130);
        assert_eq!(quality_quantizer(14 * DAY_MS, true, 190), 160);
        assert_eq!(quality_quantizer(28 * DAY_MS, true, 190), 190);
        assert_eq!(quality_quantizer(365 * DAY_MS, false, 190), 100);
        assert_eq!(quality_quantizer(28 * DAY_MS, true, 999), 240);
    }

    #[test]
    fn decoder_output_parser_requires_exact_i420_frames() {
        let mut bytes = b"ARYI4201".to_vec();
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u32.to_le_bytes());
        bytes.extend_from_slice(&384_u32.to_le_bytes());
        bytes.extend(std::iter::repeat_n(7, 384));
        let decoded = parse_decoder_output(&bytes).unwrap();
        assert_eq!((decoded.width, decoded.height), (16, 16));
        assert_eq!(decoded.frames, vec![vec![7; 384]]);

        bytes.push(0);
        assert!(parse_decoder_output(&bytes).is_err());

        let bounded = std::io::Cursor::new(&bytes[..bytes.len() - 1]);
        assert!(read_decoder_output(bounded, bytes.len() - 2).is_err());
    }
}
