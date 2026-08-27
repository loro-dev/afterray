use afterray_models::AdapterError;
use rubato::{FastFixedIn, PolynomialDegree, Resampler};
use std::{fs::File, path::Path};
use symphonia::core::{
    audio::{Channels, SampleBuffer},
    codecs::DecoderOptions,
    formats::FormatOptions,
    io::{MediaSourceStream, MediaSourceStreamOptions},
    meta::MetadataOptions,
    probe::Hint,
};

/// Decode any container Symphonia understands (m4a/AAC from capture, wav, mp3)
/// into mono f32 at 16 kHz.
pub fn load_mono_16k(path: &Path) -> Result<Vec<f32>, AdapterError> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|ext| ext.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|error| AdapterError::InvalidOutput(format!("could not probe audio: {error}")))?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| AdapterError::InvalidOutput("audio file has no default track".into()))?;
    let track_id = track.id;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| AdapterError::InvalidOutput("audio track has no sample rate".into()))?;
    let channel_count = track.codec_params.channels.map_or(1, Channels::count);
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|error| AdapterError::InvalidOutput(format!("could not decode audio: {error}")))?;

    let mut interleaved = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(symphonia::core::errors::Error::IoError(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(symphonia::core::errors::Error::ResetRequired) => break,
            Err(error) => {
                return Err(AdapterError::InvalidOutput(format!(
                    "audio decode failed: {error}"
                )));
            }
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded_packet = decoder.decode(&packet).map_err(|error| {
            AdapterError::InvalidOutput(format!("audio decode failed: {error}"))
        })?;
        let spec = *decoded_packet.spec();
        let mut buffer = SampleBuffer::<f32>::new(decoded_packet.capacity() as u64, spec);
        buffer.copy_interleaved_ref(decoded_packet);
        interleaved.extend_from_slice(buffer.samples());
    }

    let mono = downmix_mono(&interleaved, channel_count.max(1));
    resample_to_16k(&mono, sample_rate)
}

const TARGET_SAMPLE_RATE: u32 = 16_000;

fn downmix_mono(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

fn resample_to_16k(samples: &[f32], sample_rate: u32) -> Result<Vec<f32>, AdapterError> {
    if sample_rate == TARGET_SAMPLE_RATE {
        return Ok(samples.to_vec());
    }
    if sample_rate == 0 {
        return Err(AdapterError::InvalidOutput(
            "audio track sample rate is zero".into(),
        ));
    }
    if samples.is_empty() {
        return Ok(Vec::new());
    }
    // Qwen3 ASR (and the aligner) derive duration from sample count at 16 kHz.
    // The output length must therefore be the source wall-clock duration, not
    // whatever the resampler emitted after padding its last 1024-frame chunk.
    let ratio = f64::from(TARGET_SAMPLE_RATE) / f64::from(sample_rate);
    let expected = resampled_frame_count(samples.len(), sample_rate);
    let mut resampler = FastFixedIn::<f32>::new(ratio, 1.0, PolynomialDegree::Septic, 1024, 1)
        .map_err(|error| AdapterError::InvalidOutput(format!("resampler failed: {error}")))?;
    let delay = resampler.output_delay();
    let mut output = Vec::with_capacity(expected.saturating_add(delay).saturating_add(1024));
    let mut offset = 0;
    while offset < samples.len() {
        let needed = resampler.input_frames_next();
        let remaining = samples.len() - offset;
        let chunk_out = if remaining >= needed {
            let chunk = &samples[offset..offset + needed];
            offset += needed;
            resampler
                .process(&[chunk], None)
                .map_err(|error| AdapterError::InvalidOutput(format!("resample failed: {error}")))?
        } else {
            let tail = &samples[offset..];
            offset = samples.len();
            let channels: [&[f32]; 1] = [tail];
            resampler
                .process_partial(Some(&channels), None)
                .map_err(|error| AdapterError::InvalidOutput(format!("resample failed: {error}")))?
        };
        output.extend_from_slice(&chunk_out[0]);
    }
    while output.len() < expected.saturating_add(delay) {
        let flushed = resampler
            .process_partial::<&[f32]>(None, None)
            .map_err(|error| AdapterError::InvalidOutput(format!("resample failed: {error}")))?;
        if flushed[0].is_empty() {
            break;
        }
        output.extend_from_slice(&flushed[0]);
    }
    let start = delay.min(output.len());
    let end = start.saturating_add(expected).min(output.len());
    let mut trimmed = output[start..end].to_vec();
    if trimmed.len() < expected {
        trimmed.resize(expected, 0.0);
    }
    Ok(trimmed)
}

fn resampled_frame_count(frames: usize, sample_rate: u32) -> usize {
    let frames = u64::try_from(frames).unwrap_or(u64::MAX);
    let scaled = frames.saturating_mul(u64::from(TARGET_SAMPLE_RATE)) / u64::from(sample_rate);
    usize::try_from(scaled).unwrap_or(usize::MAX)
}

#[cfg(test)]
mod tests {
    use super::{resample_to_16k, resampled_frame_count, TARGET_SAMPLE_RATE};

    #[test]
    fn resample_48k_keeps_wall_clock_duration() {
        let samples = vec![0.25_f32; 48_000];
        let resampled = resample_to_16k(&samples, 48_000).expect("48 kHz clip should resample");
        assert_eq!(
            resampled.len(),
            16_000,
            "a one-second 48 kHz clip must remain one second at 16 kHz"
        );
    }

    #[test]
    fn resample_preserves_duration_for_unaligned_lengths() {
        let frames = 48_000 + 17;
        let samples = vec![0.25_f32; frames];
        let resampled = resample_to_16k(&samples, 48_000).expect("unaligned clip should resample");
        assert_eq!(resampled.len(), resampled_frame_count(frames, 48_000));
    }

    #[test]
    fn already_16k_is_unchanged() {
        let samples: Vec<f32> = (0..1_600).map(|index| index as f32).collect();
        let resampled = resample_to_16k(&samples, TARGET_SAMPLE_RATE).expect("identity resample");
        assert_eq!(resampled, samples);
    }
}
