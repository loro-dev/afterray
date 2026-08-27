//! JPEG → tightly packed I420 for the packer.

use crate::{CodecError, i420_len};
use zeroize::{Zeroize, Zeroizing};
use zune_jpeg::JpegDecoder;
use zune_jpeg::zune_core::colorspace::ColorSpace;
use zune_jpeg::zune_core::options::DecoderOptions;

/// Decode a JPEG still to 8-bit I420. Odd dimensions are cropped to even.
pub fn jpeg_to_i420(jpeg: &[u8]) -> Result<(u32, u32, Zeroizing<Vec<u8>>), CodecError> {
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut decoder = JpegDecoder::new_with_options(jpeg, options);
    let rgb = decoder
        .decode()
        .map_err(|error| CodecError::Jpeg(error.to_string()))?;
    let info = decoder
        .info()
        .ok_or_else(|| CodecError::Jpeg("jpeg has no frame header".into()))?;
    let src_w = u32::from(info.width);
    let src_h = u32::from(info.height);
    if src_w < 16 || src_h < 16 {
        return Err(CodecError::InvalidDimensions {
            width: src_w,
            height: src_h,
        });
    }
    let width = src_w & !1;
    let height = src_h & !1;
    let mut yuv = Zeroizing::new(vec![0_u8; i420_len(width, height)]);
    rgb_to_i420(&rgb, src_w, width, height, &mut yuv);
    let mut rgb = rgb;
    rgb.zeroize();
    Ok((width, height, yuv))
}

fn rgb_to_i420(rgb: &[u8], src_width: u32, width: u32, height: u32, yuv: &mut [u8]) {
    let width = width as usize;
    let height = height as usize;
    let src_width = src_width as usize;
    let y_size = width * height;
    let uv_w = width / 2;
    let uv_size = uv_w * (height / 2);
    let (y_plane, rest) = yuv.split_at_mut(y_size);
    let (u_plane, v_plane) = rest.split_at_mut(uv_size);

    for row in 0..height {
        for col in 0..width {
            let src = (row * src_width + col) * 3;
            let r = i32::from(rgb[src]);
            let g = i32::from(rgb[src + 1]);
            let b = i32::from(rgb[src + 2]);
            y_plane[row * width + col] =
                u8::try_from(((66 * r + 129 * g + 25 * b + 128) >> 8).saturating_add(16))
                    .expect("BT.601 luma stays in the limited-range u8 interval");
            if row % 2 == 0 && col % 2 == 0 {
                let uv = (row / 2) * uv_w + col / 2;
                u_plane[uv] =
                    u8::try_from(((-38 * r - 74 * g + 112 * b + 128) >> 8).saturating_add(128))
                        .expect("BT.601 blue chroma stays in the limited-range u8 interval");
                v_plane[uv] =
                    u8::try_from(((112 * r - 94 * g - 18 * b + 128) >> 8).saturating_add(128))
                        .expect("BT.601 red chroma stays in the limited-range u8 interval");
            }
        }
    }
}
