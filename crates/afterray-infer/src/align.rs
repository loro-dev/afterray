use crate::missing_model;
use afterray_models::{AdapterError, TranscriptCue, TranscriptTimingKind};
use qwen_asr::align::AlignResult;
use std::path::Path;

const CUE_GAP_MS: f32 = 750.0;
const CUE_MAX_DURATION_MS: f32 = 6_000.0;
const CUE_MAX_CHARACTERS: usize = 56;

// @dec:forced-aligned-audio-transcript-cues — docs/decisions/active/product/2026-08-24-forced-aligned-audio-transcript-cues.md
pub fn align_transcript(
    model_dir: &Path,
    audio_path: &Path,
    text: &str,
    language: &str,
) -> Result<Vec<TranscriptCue>, AdapterError> {
    if !model_dir.join("config.json").is_file() {
        return Err(missing_model(
            model_dir,
            "download the Qwen3 subtitle aligner pack or set AFTERRAY_ALIGNER_MODEL",
        ));
    }
    let model_path = model_dir.to_str().ok_or_else(|| {
        AdapterError::MissingModel("Qwen3 aligner path is not valid UTF-8".into())
    })?;
    let mut context = qwen_asr::context::QwenCtx::load(model_path).ok_or_else(|| {
        AdapterError::MissingModel(format!(
            "could not load Qwen3 subtitle aligner from `{}`",
            model_dir.display()
        ))
    })?;
    let samples = crate::audio::load_mono_16k(audio_path)?;
    if samples.is_empty() || text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let language = alignment_language(language).ok_or_else(|| {
        AdapterError::InvalidOutput(format!(
            "Qwen3 subtitle alignment does not support language `{language}`"
        ))
    })?;
    let aligned = qwen_asr::align::forced_align(&mut context, &samples, text, language)
        .ok_or_else(|| AdapterError::Process("Qwen3 subtitle alignment failed".into()))?;
    let sample_count = i64::try_from(samples.len()).unwrap_or(i64::MAX);
    let duration_ms = sample_count.saturating_mul(1_000) / 16_000;
    bound_cues_to_duration(group_alignment(&aligned, language), duration_ms).ok_or_else(|| {
        AdapterError::InvalidOutput(
            "Qwen3 subtitle alignment returned empty, overlapping, or out-of-range cues".into(),
        )
    })
}

/// Canonical language labels accepted by the official 0.6B forced aligner.
pub(crate) fn alignment_language(language: &str) -> Option<&'static str> {
    match language.trim().to_ascii_lowercase().as_str() {
        "zh" | "zh-cn" | "zh-hans" | "cmn" | "chinese" => Some("Chinese"),
        "yue" | "zh-hk" | "zh-yue" | "cantonese" => Some("Cantonese"),
        "en" | "english" => Some("English"),
        "de" | "german" => Some("German"),
        "es" | "spanish" => Some("Spanish"),
        "fr" | "french" => Some("French"),
        "it" | "italian" => Some("Italian"),
        "pt" | "portuguese" => Some("Portuguese"),
        "ru" | "russian" => Some("Russian"),
        "ko" | "korean" => Some("Korean"),
        "ja" | "jp" | "japanese" => Some("Japanese"),
        _ => None,
    }
}

fn group_alignment(items: &[AlignResult], language: &str) -> Vec<TranscriptCue> {
    let cjk = matches!(language, "Chinese" | "Cantonese" | "Japanese" | "Korean");
    let mut cues = Vec::new();
    let mut current = String::new();
    let mut start_ms = 0.0_f32;
    let mut end_ms = 0.0_f32;

    for item in items.iter().filter(|item| {
        !item.text.trim().is_empty()
            && item.start_ms.is_finite()
            && item.end_ms.is_finite()
            && item.end_ms >= item.start_ms
    }) {
        let gap = if current.is_empty() {
            0.0
        } else {
            (item.start_ms - end_ms).max(0.0)
        };
        let would_overflow = !current.is_empty()
            && (gap >= CUE_GAP_MS
                || item.end_ms - start_ms >= CUE_MAX_DURATION_MS
                || current.chars().count() + item.text.chars().count() > CUE_MAX_CHARACTERS);
        if would_overflow {
            push_cue(&mut cues, &mut current, start_ms, end_ms);
        }
        if current.is_empty() {
            start_ms = item.start_ms.max(0.0);
        } else if !cjk && needs_space(&current, &item.text) {
            current.push(' ');
        }
        current.push_str(item.text.trim());
        end_ms = item.end_ms.max(start_ms);
        if ends_sentence(&item.text) {
            push_cue(&mut cues, &mut current, start_ms, end_ms);
        }
    }
    push_cue(&mut cues, &mut current, start_ms, end_ms);
    cues
}

/// The aligner works on padded 80 ms timestamp frames, so its last edge may
/// extend just past the decoded PCM. Normalize at the inference trust boundary
/// before the stricter persisted-segment bound is applied by the daemon.
fn bound_cues_to_duration(
    cues: Vec<TranscriptCue>,
    duration_ms: i64,
) -> Option<Vec<TranscriptCue>> {
    if duration_ms <= 0 || cues.is_empty() {
        return None;
    }
    let mut bounded: Vec<TranscriptCue> = Vec::with_capacity(cues.len());
    for mut cue in cues {
        let previous_end_ms = bounded.last().map_or(0, |previous| previous.end_offset_ms);
        if cue.start_offset_ms < previous_end_ms
            || cue.start_offset_ms < 0
            || cue.start_offset_ms >= duration_ms
        {
            return None;
        }
        cue.ordinal = u32::try_from(bounded.len()).unwrap_or(u32::MAX);
        cue.end_offset_ms = cue.end_offset_ms.min(duration_ms);
        if cue.end_offset_ms <= cue.start_offset_ms {
            return None;
        }
        bounded.push(cue);
    }
    Some(bounded)
}

// Alignment outputs finite millisecond offsets for one bounded audio file; the
// integer wire/storage clock intentionally rounds away sub-millisecond detail.
#[allow(clippy::cast_possible_truncation)]
fn push_cue(cues: &mut Vec<TranscriptCue>, current: &mut String, start_ms: f32, end_ms: f32) {
    let text = current.trim();
    if !text.is_empty() {
        cues.push(TranscriptCue {
            ordinal: u32::try_from(cues.len()).unwrap_or(u32::MAX),
            text: text.to_owned(),
            start_offset_ms: start_ms.round() as i64,
            end_offset_ms: end_ms.max(start_ms + 1.0).round() as i64,
            timing_kind: TranscriptTimingKind::Aligned,
        });
    }
    current.clear();
}

fn needs_space(before: &str, after: &str) -> bool {
    let Some(first) = after.chars().next() else {
        return false;
    };
    let Some(last) = before.chars().next_back() else {
        return false;
    };
    !matches!(first, '.' | ',' | '!' | '?' | ':' | ';' | ')' | ']' | '}')
        && !matches!(last, '(' | '[' | '{')
}

fn ends_sentence(text: &str) -> bool {
    text.trim_end()
        .chars()
        .next_back()
        .is_some_and(|character| matches!(character, '.' | '!' | '?' | '。' | '！' | '？' | '…'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(text: &str, start_ms: f32, end_ms: f32) -> AlignResult {
        AlignResult {
            text: text.into(),
            start_ms,
            end_ms,
        }
    }

    #[test]
    fn groups_english_words_at_sentence_and_silence_boundaries() {
        let cues = group_alignment(
            &[
                item("Hello", 100.0, 400.0),
                item("world.", 450.0, 800.0),
                item("Next", 1_800.0, 2_050.0),
                item("thought", 2_100.0, 2_500.0),
            ],
            "English",
        );
        assert_eq!(cues.len(), 2);
        assert_eq!(cues[0].text, "Hello world.");
        assert_eq!((cues[0].start_offset_ms, cues[0].end_offset_ms), (100, 800));
        assert_eq!(cues[1].text, "Next thought");
    }

    #[test]
    fn joins_cjk_characters_without_spaces() {
        let cues = group_alignment(
            &[
                item("你", 0.0, 100.0),
                item("好", 100.0, 200.0),
                item("。", 200.0, 240.0),
            ],
            "Chinese",
        );
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].text, "你好。");
        assert_eq!(cues[0].timing_kind, TranscriptTimingKind::Aligned);
    }

    #[test]
    fn canonicalizes_supported_languages_only() {
        assert_eq!(alignment_language("zh-CN"), Some("Chinese"));
        assert_eq!(alignment_language("English"), Some("English"));
        assert_eq!(alignment_language("Arabic"), None);
    }

    #[test]
    fn clips_final_aligner_padding_without_retiming_text() {
        let cues = bound_cues_to_duration(
            vec![
                TranscriptCue {
                    ordinal: 4,
                    text: "First".into(),
                    start_offset_ms: 100,
                    end_offset_ms: 800,
                    timing_kind: TranscriptTimingKind::Aligned,
                },
                TranscriptCue {
                    ordinal: 5,
                    text: "second".into(),
                    start_offset_ms: 850,
                    end_offset_ms: 1_080,
                    timing_kind: TranscriptTimingKind::Aligned,
                },
            ],
            1_000,
        )
        .expect("the final cue overlaps real audio and should only be clipped");
        assert_eq!(cues.len(), 2);
        assert_eq!(
            (cues[1].start_offset_ms, cues[1].end_offset_ms),
            (850, 1_000)
        );
        assert_eq!(cues[1].text, "second");
        assert_eq!(cues[1].ordinal, 1);
    }

    #[test]
    fn rejects_cues_that_would_require_false_retiming() {
        let cue = |ordinal, text: &str, start_offset_ms, end_offset_ms| TranscriptCue {
            ordinal,
            text: text.into(),
            start_offset_ms,
            end_offset_ms,
            timing_kind: TranscriptTimingKind::Aligned,
        };
        assert!(
            bound_cues_to_duration(
                vec![cue(0, "first", 100, 900), cue(1, "overlap", 850, 1_000)],
                1_000,
            )
            .is_none()
        );
        assert!(
            bound_cues_to_duration(
                vec![cue(0, "first", 100, 900), cue(1, "outside", 1_000, 1_080)],
                1_000,
            )
            .is_none()
        );
        assert!(bound_cues_to_duration(Vec::new(), 1_000).is_none());
    }

    #[test]
    #[ignore = "requires a downloaded aligner and an explicitly supplied non-silent audio file"]
    fn real_non_silent_audio_produces_bounded_ordered_cues() {
        let model_dir = std::env::var_os("AFTERRAY_ALIGNER_MODEL")
            .map(std::path::PathBuf::from)
            .expect("set AFTERRAY_ALIGNER_MODEL to the prepared aligner directory");
        let audio_path = std::env::var_os("AFTERRAY_ALIGNMENT_AUDIO")
            .map(std::path::PathBuf::from)
            .expect("set AFTERRAY_ALIGNMENT_AUDIO to a non-silent audio file");
        let text = std::env::var("AFTERRAY_ALIGNMENT_TEXT")
            .expect("set AFTERRAY_ALIGNMENT_TEXT to the audio's exact transcript");
        let language =
            std::env::var("AFTERRAY_ALIGNMENT_LANGUAGE").unwrap_or_else(|_| "English".into());

        let audio = crate::audio::load_mono_16k(&audio_path).expect("decode acceptance audio");
        assert!(
            audio.iter().any(|sample| sample.abs() > 0.001),
            "acceptance audio must be non-silent"
        );
        let duration_ms =
            i64::try_from(audio.len()).expect("audio sample count fits i64") * 1_000 / 16_000;
        let cues = align_transcript(&model_dir, &audio_path, &text, &language)
            .expect("forced alignment should succeed");
        assert!(!cues.is_empty(), "non-silent speech must produce cues");

        let mut previous_end_ms = 0_i64;
        for (index, cue) in cues.iter().enumerate() {
            assert_eq!(
                cue.ordinal,
                u32::try_from(index).expect("cue count fits u32")
            );
            assert_eq!(cue.timing_kind, TranscriptTimingKind::Aligned);
            assert!(!cue.text.trim().is_empty());
            assert!(cue.start_offset_ms >= previous_end_ms);
            assert!(cue.end_offset_ms > cue.start_offset_ms);
            assert!(cue.end_offset_ms <= duration_ms);
            previous_end_ms = cue.end_offset_ms;
        }
        eprintln!("aligned {duration_ms} ms into {cues:#?}");
    }
}
