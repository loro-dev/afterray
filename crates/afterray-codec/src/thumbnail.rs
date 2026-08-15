//! Small JPEG thumbnails for the search filmstrip.
//!
//! Thumbnails must be produced while a still is still a JPEG. This crate can
//! encode AV1 but cannot decode it, so once the packer folds a still into a
//! cold GOP there is no way back to pixels on the Rust side — see
//! `docs/hot-stills-cold-gop.md`.

use crate::CodecError;
use jpeg_encoder::{ColorType, Encoder};
use zeroize::Zeroize;
use zune_jpeg::JpegDecoder;
use zune_jpeg::zune_core::colorspace::ColorSpace;
use zune_jpeg::zune_core::options::DecoderOptions;

/// Long edge of a generated thumbnail, in pixels. Roughly 10% of a Retina
/// capture's long edge, which lands well under 1% of the original's bytes.
pub const DEFAULT_THUMBNAIL_MAX_EDGE: u32 = 360;

/// Filmstrip cells are ~132pt wide. Quality below this starts showing blocking
/// on text-heavy screenshots, which is most of what `AfterRay` captures.
const THUMBNAIL_QUALITY: u8 = 62;

/// Decodes a captured still and re-encodes it as a thumbnail JPEG whose long
/// edge is at most `max_edge`. Never upscales.
pub fn still_thumbnail(jpeg: &[u8], max_edge: u32) -> Result<Vec<u8>, CodecError> {
    if max_edge == 0 {
        return Err(CodecError::InvalidDimensions {
            width: max_edge,
            height: max_edge,
        });
    }
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut decoder = JpegDecoder::new_with_options(jpeg, options);
    let mut rgb = decoder
        .decode()
        .map_err(|error| CodecError::Jpeg(error.to_string()))?;
    let info = decoder
        .info()
        .ok_or_else(|| CodecError::Jpeg("jpeg has no frame header".into()))?;
    let source_width = u32::from(info.width);
    let source_height = u32::from(info.height);
    if source_width == 0 || source_height == 0 {
        rgb.zeroize();
        return Err(CodecError::InvalidDimensions {
            width: source_width,
            height: source_height,
        });
    }

    let (width, height) = fit_within(source_width, source_height, max_edge);
    let mut scaled = downscale_rgb(&rgb, source_width, source_height, width, height);
    rgb.zeroize();

    let mut out = Vec::new();
    let result = Encoder::new(&mut out, THUMBNAIL_QUALITY).encode(
        &scaled,
        width as u16,
        height as u16,
        ColorType::Rgb,
    );
    scaled.zeroize();
    result.map_err(|error| CodecError::Jpeg(error.to_string()))?;
    Ok(out)
}

/// Largest size with the source aspect ratio whose long edge is `max_edge`.
/// Sources already smaller than `max_edge` are returned untouched.
fn fit_within(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    let long_edge = width.max(height);
    if long_edge <= max_edge {
        return (width, height);
    }
    // Integer math with round-half-up: no float casts, no sign to lose.
    let scale = |edge: u32| -> u32 {
        let numerator = u64::from(edge) * u64::from(max_edge) + u64::from(long_edge) / 2;
        u32::try_from(numerator / u64::from(long_edge))
            .unwrap_or(max_edge)
            .max(1)
    };
    (scale(width), scale(height))
}

/// Box filter. Averaging every source pixel that lands in a destination cell
/// keeps small on-screen text legible; point sampling at 10% turns it to noise.
fn downscale_rgb(
    source: &[u8],
    source_width: u32,
    source_height: u32,
    width: u32,
    height: u32,
) -> Vec<u8> {
    let width_usize = width as usize;
    let height_usize = height as usize;
    let source_width_usize = source_width as usize;
    let mut destination = vec![0_u8; width_usize * height_usize * 3];
    if width == source_width && height == source_height {
        let needed = source_width_usize * source_height as usize * 3;
        destination.copy_from_slice(&source[..needed]);
        return destination;
    }

    for row in 0..height_usize {
        let (top, bottom) = span(row, height_usize, source_height as usize);
        for column in 0..width_usize {
            let (left, right) = span(column, width_usize, source_width_usize);
            let mut totals = [0_u64; 3];
            let mut samples = 0_u64;
            for source_row in top..bottom {
                let row_offset = source_row * source_width_usize;
                for source_column in left..right {
                    let index = (row_offset + source_column) * 3;
                    totals[0] += u64::from(source[index]);
                    totals[1] += u64::from(source[index + 1]);
                    totals[2] += u64::from(source[index + 2]);
                    samples += 1;
                }
            }
            let index = (row * width_usize + column) * 3;
            for channel in 0..3 {
                destination[index + channel] = (totals[channel] / samples.max(1)) as u8;
            }
        }
    }
    destination
}

/// Half-open source range covering destination index `index`, always at least
/// one pixel wide so no destination cell samples nothing.
fn span(index: usize, destination_extent: usize, source_extent: usize) -> (usize, usize) {
    let start = index * source_extent / destination_extent;
    let end = ((index + 1) * source_extent / destination_extent).max(start + 1);
    (start.min(source_extent - 1), end.min(source_extent))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Encodes a solid-color RGB image as a baseline JPEG to feed the decoder.
    fn solid_jpeg(width: u16, height: u16, color: [u8; 3]) -> Vec<u8> {
        let mut pixels = Vec::with_capacity(width as usize * height as usize * 3);
        for _ in 0..(width as usize * height as usize) {
            pixels.extend_from_slice(&color);
        }
        let mut out = Vec::new();
        Encoder::new(&mut out, 92)
            .encode(&pixels, width, height, ColorType::Rgb)
            .unwrap();
        out
    }

    #[test]
    fn fit_within_preserves_aspect_and_never_upscales() {
        assert_eq!(fit_within(3456, 2234, 360), (360, 233));
        assert_eq!(fit_within(2234, 3456, 360), (233, 360));
        assert_eq!(fit_within(320, 200, 360), (320, 200));
        assert_eq!(fit_within(1, 4000, 360), (1, 360));
    }

    #[test]
    fn span_always_covers_at_least_one_source_pixel() {
        // Destination wider than the source: every cell still samples a pixel.
        for index in 0..8 {
            let (start, end) = span(index, 8, 3);
            assert!(end > start, "empty span at {index}");
            assert!(end <= 3);
        }
    }

    #[test]
    fn thumbnail_shrinks_to_the_requested_long_edge() {
        let source = solid_jpeg(800, 500, [200, 40, 30]);
        let thumbnail = still_thumbnail(&source, 100).unwrap();

        let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
        let mut decoder = JpegDecoder::new_with_options(thumbnail.as_slice(), options);
        decoder.decode().unwrap();
        let info = decoder.info().unwrap();
        assert_eq!(info.width, 100);
        assert_eq!(info.height, 63);
        assert!(
            thumbnail.len() < source.len(),
            "thumbnail {} bytes is not smaller than source {} bytes",
            thumbnail.len(),
            source.len()
        );
    }

    #[test]
    fn thumbnail_preserves_the_average_color() {
        let source = solid_jpeg(640, 640, [30, 160, 90]);
        let thumbnail = still_thumbnail(&source, 64).unwrap();

        let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
        let mut decoder = JpegDecoder::new_with_options(thumbnail.as_slice(), options);
        let pixels = decoder.decode().unwrap();
        let center = (pixels.len() / 2 / 3) * 3;
        assert!(pixels[center].abs_diff(30) <= 12, "red drifted");
        assert!(pixels[center + 1].abs_diff(160) <= 12, "green drifted");
        assert!(pixels[center + 2].abs_diff(90) <= 12, "blue drifted");
    }

    #[test]
    fn smaller_source_is_not_upscaled() {
        let source = solid_jpeg(120, 80, [10, 10, 10]);
        let thumbnail = still_thumbnail(&source, DEFAULT_THUMBNAIL_MAX_EDGE).unwrap();

        let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
        let mut decoder = JpegDecoder::new_with_options(thumbnail.as_slice(), options);
        decoder.decode().unwrap();
        let info = decoder.info().unwrap();
        assert_eq!((info.width, info.height), (120, 80));
    }

    #[test]
    fn non_jpeg_input_is_rejected() {
        assert!(still_thumbnail(b"not a jpeg at all", 360).is_err());
    }
}
