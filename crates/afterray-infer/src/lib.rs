//! In-process ASR, embedding, and LLM backends used by `afterray-model-worker`.

#![allow(
    clippy::cast_precision_loss,
    clippy::missing_errors_doc,
    clippy::similar_names
)]

mod asr;
mod audio;
mod embed;

use afterray_models::{AdapterError, ModelInput, ModelOutput};
use std::path::PathBuf;

pub use asr::transcribe;
pub use audio::load_mono_16k;
pub use embed::embed_text;

#[derive(Debug, Clone)]
pub struct InferConfig {
    pub asr_model: PathBuf,
    pub embedding_model: PathBuf,
}

impl InferConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let catalog = afterray_models::default_catalog();
        let path_for = |id: &str| {
            catalog
                .iter()
                .find(|spec| spec.id == id)
                .map_or_else(PathBuf::new, |spec| spec.path.clone())
        };
        Self {
            asr_model: path_for("asr"),
            embedding_model: path_for("embedding"),
        }
    }
}

pub fn execute(config: &InferConfig, input: &ModelInput) -> Result<ModelOutput, AdapterError> {
    match input {
        ModelInput::Ocr { .. } => Err(AdapterError::InvalidOutput(
            "OCR must be routed to afterray-native-model-worker".into(),
        )),
        ModelInput::Asr {
            audio_path,
            language,
        } => {
            let (text, detected) = transcribe(&config.asr_model, audio_path, language.as_deref())?;
            Ok(ModelOutput::Asr {
                text,
                language: detected.or_else(|| language.clone()),
            })
        }
        ModelInput::Embedding { text } => Ok(ModelOutput::Embedding {
            vector: embed_text(&config.embedding_model, text)?,
        }),
        ModelInput::Llm { .. } => Err(AdapterError::InvalidOutput(
            "LLM generation runs on the MLX worker or a configured endpoint, not this worker".into(),
        )),
    }
}

pub(crate) fn missing_model(path: &std::path::Path, hint: &str) -> AdapterError {
    AdapterError::MissingModel(format!(
        "model asset `{}` is missing; {hint}",
        path.display()
    ))
}

pub(crate) fn sanitize_asr_text(text: &str) -> String {
    let cleaned = text.trim();
    let words: Vec<_> = cleaned
        .split(|ch: char| !ch.is_ascii_alphabetic() && ch != '\'')
        .filter(|word| !word.is_empty())
        .map(str::to_ascii_lowercase)
        .collect();
    if words.len() < 4 {
        return cleaned.to_owned();
    }
    let filler = ["thank", "thanks", "you", "thankyou"];
    let hits = words
        .iter()
        .filter(|word| filler.contains(&word.as_str()))
        .count();
    if hits * 10 / words.len() >= 7 {
        String::new()
    } else {
        cleaned.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize_asr_text;

    #[test]
    fn drops_thank_you_loops() {
        assert_eq!(sanitize_asr_text("Thank you thank you thank you"), "");
        assert_eq!(sanitize_asr_text("hello there"), "hello there");
    }
}
