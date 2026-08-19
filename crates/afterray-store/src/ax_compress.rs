//! zstd-compress accessibility snapshot JSON before encryption.
//!
//! Detect compressed payloads by the zstd magic so legacy uncompressed AX
//! still decrypts. OCR crop, T1, and acts-join still parse `root`; do not
//! strip it here.

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];
/// zstd level 3 matched the vault design notes (~5× on AX JSON).
const ZSTD_LEVEL: i32 = 3;

#[must_use]
pub fn prepare_accessibility_artifact(bytes: &[u8]) -> Vec<u8> {
    maybe_zstd_compress(bytes)
}

#[must_use]
pub fn maybe_zstd_compress(bytes: &[u8]) -> Vec<u8> {
    match zstd::encode_all(bytes, ZSTD_LEVEL) {
        Ok(compressed) if compressed.len() < bytes.len() => compressed,
        _ => bytes.to_vec(),
    }
}

/// Decompress a zstd payload; leave anything else untouched (JPEG / IVF / m4a /
/// legacy uncompressed AX JSON).
#[must_use]
pub fn maybe_zstd_decompress(bytes: Vec<u8>) -> Vec<u8> {
    if bytes.len() >= 4 && bytes[..4] == ZSTD_MAGIC {
        zstd::decode_all(bytes.as_slice()).unwrap_or(bytes)
    } else {
        bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zstd_round_trips_and_shrinks_json() {
        let raw = br#"{"root":{"role":"AXWindow","children":[
            {"role":"AXStaticText","value":"hello world hello world hello world"},
            {"role":"AXStaticText","value":"hello world hello world hello world"},
            {"role":"AXStaticText","value":"hello world hello world hello world"}
        ]}}"#;
        let compressed = maybe_zstd_compress(raw);
        assert!(compressed.len() < raw.len());
        assert_eq!(&compressed[..4], &ZSTD_MAGIC);
        let restored = maybe_zstd_decompress(compressed);
        assert_eq!(restored, raw);
    }

    #[test]
    fn jpeg_bytes_are_left_alone() {
        let jpeg = [0xFF, 0xD8, 0xFF, 0xD9];
        let out = maybe_zstd_decompress(jpeg.to_vec());
        assert_eq!(out, jpeg);
    }
}
