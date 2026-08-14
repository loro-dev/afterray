//! Closed-GOP AV1 encoder for the AfterRay cold archive.
//!
//! The packer feeds 8-bit I420 frames and persists IVF bytes. This crate is
//! **not** linked into the capture shim.
//!
//! Recommended product settings (live-vault sim, 2026-08-14):
//! rav1e speed=8, quantizer=100, tiles=4, keyint=30.

#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::cast_possible_truncation
)]

mod encoder;
mod ivf;
mod jpeg;
mod thumbnail;

pub use encoder::Rav1eEncoder;
pub use ivf::{
    IVF_FOURCC_AV01, IVF_FRAME_HEADER_LEN, IVF_HEADER_LEN, IVF_MAGIC, Ivf, IvfError, IvfFrame,
    is_ivf, mux_ivf, parse_ivf, slice_ivf,
};
pub use jpeg::jpeg_to_i420;
pub use thumbnail::{DEFAULT_THUMBNAIL_MAX_EDGE, still_thumbnail};

pub const CODEC_AV01: &str = "av01";
pub const ENCODER_RAV1E: &str = "rav1e";
pub const CONTENT_TYPE_IVF_AV01: &str = "video/x-ivf; codec=av01";
pub const CONTENT_TYPE_JPEG: &str = "image/jpeg";

/// Product defaults measured against the live vault.
pub const RAV1E_SPEED: u8 = 8;
pub const RAV1E_QUANTIZER: usize = 100;
pub const RAV1E_TILES: usize = 4;
pub const DEFAULT_KEYINT: u16 = 30;

/// Tightly packed 8-bit I420 length (`Y` then `U` then `V`).
#[must_use]
pub fn i420_len(width: u32, height: u32) -> usize {
    let y = width as usize * height as usize;
    y + y / 2
}

pub struct GopFrameInput<'a> {
    pub moment_id: &'a str,
    pub captured_at_ms: i64,
    pub width: u32,
    pub height: u32,
    pub yuv: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedGopFrame {
    pub index: u16,
    pub is_keyframe: bool,
    pub byte_offset: u32,
    pub byte_length: u32,
    pub content_hash: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedGop {
    pub codec: &'static str,
    pub encoder: String,
    pub encoder_version: String,
    pub width: u32,
    pub height: u32,
    pub keyint: u16,
    pub ivf: Vec<u8>,
    pub frames: Vec<EncodedGopFrame>,
}

impl Drop for EncodedGop {
    fn drop(&mut self) {
        use zeroize::Zeroize as _;
        self.ivf.zeroize();
    }
}

#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("closed GOP needs at least one frame")]
    EmptyGop,
    #[error("GOP of {0} frames exceeds u16 keyint")]
    GopTooLong(usize),
    #[error("invalid I420 dimensions {width}x{height} (need even, >= 16)")]
    InvalidDimensions { width: u32, height: u32 },
    #[error("frame {index} is {width}x{height}, expected {expected_width}x{expected_height}")]
    MismatchedDimensions {
        index: usize,
        expected_width: u32,
        expected_height: u32,
        width: u32,
        height: u32,
    },
    #[error("frame {index} I420 length {actual}, expected {expected}")]
    InvalidI420 {
        index: usize,
        expected: usize,
        actual: usize,
    },
    #[error("rav1e: {0}")]
    Encode(String),
    #[error("jpeg: {0}")]
    Jpeg(String),
    #[error(transparent)]
    Ivf(#[from] IvfError),
}

pub trait Av1Encoder: Send {
    fn encode_closed_gop(&self, frames: &[GopFrameInput<'_>]) -> Result<EncodedGop, CodecError>;
}

pub fn encode_closed_gop(frames: &[GopFrameInput<'_>]) -> Result<EncodedGop, CodecError> {
    Rav1eEncoder::default().encode_closed_gop(frames)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    const FIXTURE_WIDTH: u32 = 64;
    const FIXTURE_HEIGHT: u32 = 64;

    fn synthetic_i420(width: u32, height: u32, seed: u8) -> Vec<u8> {
        let y_size = (width * height) as usize;
        let uv_size = (width * height / 4) as usize;
        let mut buf = vec![0u8; y_size + 2 * uv_size];
        for (index, sample) in buf[..y_size].iter_mut().enumerate() {
            *sample = seed.wrapping_add((index % 211) as u8).saturating_add(16);
        }
        for sample in &mut buf[y_size..y_size + uv_size] {
            *sample = 128u8.wrapping_add(seed / 4);
        }
        for sample in &mut buf[y_size + uv_size..] {
            *sample = 128u8.wrapping_sub(seed / 5);
        }
        buf
    }

    fn proof_frames() -> Vec<GopFrameInput<'static>> {
        let planes: &'static [Vec<u8>] = Box::leak(Box::new([
            synthetic_i420(FIXTURE_WIDTH, FIXTURE_HEIGHT, 10),
            synthetic_i420(FIXTURE_WIDTH, FIXTURE_HEIGHT, 80),
            synthetic_i420(FIXTURE_WIDTH, FIXTURE_HEIGHT, 160),
        ]));
        vec![
            GopFrameInput {
                moment_id: "m0",
                captured_at_ms: 1_000,
                width: FIXTURE_WIDTH,
                height: FIXTURE_HEIGHT,
                yuv: planes[0].as_slice(),
            },
            GopFrameInput {
                moment_id: "m1",
                captured_at_ms: 11_000,
                width: FIXTURE_WIDTH,
                height: FIXTURE_HEIGHT,
                yuv: planes[1].as_slice(),
            },
            GopFrameInput {
                moment_id: "m2",
                captured_at_ms: 21_000,
                width: FIXTURE_WIDTH,
                height: FIXTURE_HEIGHT,
                yuv: planes[2].as_slice(),
            },
        ]
    }

    #[test]
    fn encode_closed_gop_emits_ivf_with_multiple_frames() {
        let frames = proof_frames();
        let gop = encode_closed_gop(&frames).expect("rav1e encode");
        assert_eq!(gop.codec, "av01");
        assert_eq!(gop.encoder, "rav1e");
        assert_eq!(gop.width, FIXTURE_WIDTH);
        assert_eq!(gop.height, FIXTURE_HEIGHT);
        assert_eq!(gop.keyint, 3);
        assert!(gop.ivf.starts_with(IVF_MAGIC));
        assert_eq!(&gop.ivf[8..12], b"AV01");
        let parsed = parse_ivf(&gop.ivf).expect("parse encoded IVF");
        assert_eq!(parsed.frames.len(), 3);
        assert!(gop.frames[0].is_keyframe);
        assert!(!gop.frames[1].is_keyframe);
    }

    #[test]
    fn encode_rejects_empty_gop() {
        assert!(matches!(
            encode_closed_gop(&[]).unwrap_err(),
            CodecError::EmptyGop
        ));
    }

    #[test]
    fn golden_fixture_is_dkif_with_multiple_frames() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/closed-gop-64x64.ivf");
        let bytes = std::fs::read(&path).expect("read golden IVF");
        assert!(bytes.starts_with(IVF_MAGIC));
        let parsed = parse_ivf(&bytes).expect("parse golden IVF");
        assert_eq!(&parsed.fourcc, b"AV01");
        assert_eq!(parsed.width, 64);
        assert_eq!(parsed.height, 64);
        assert!(parsed.frames.len() > 1);
    }
}
