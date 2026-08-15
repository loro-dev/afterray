use crate::missing_model;
use afterray_models::AdapterError;
use llama_cpp_2::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{AddBos, LlamaChatMessage, LlamaModel, params::LlamaModelParams},
    sampling::LlamaSampler,
};
use std::{num::NonZeroU32, path::Path, sync::OnceLock};

pub(crate) const QWEN_IM_START: &str = "<|im_start|>";
pub(crate) const QWEN_IM_END: &str = "<|im_end|>";
const DEFAULT_N_CTX: u32 = 16_384;
const DEFAULT_N_BATCH: u32 = 2_048;
const DEFAULT_MAX_TOKENS: u32 = 512;

fn backend() -> Result<&'static LlamaBackend, AdapterError> {
    static BACKEND: OnceLock<Result<LlamaBackend, String>> = OnceLock::new();
    match BACKEND.get_or_init(|| LlamaBackend::init().map_err(|error| error.to_string())) {
        Ok(backend) => Ok(backend),
        Err(error) => Err(AdapterError::Process(error.clone())),
    }
}

pub fn generate(
    model_path: &Path,
    prompt: &str,
    system: Option<&str>,
) -> Result<String, AdapterError> {
    if !model_path.is_file() {
        return Err(missing_model(
            model_path,
            "set AFTERRAY_LLM_MODEL or download the LLM pack",
        ));
    }
    let backend = backend()?;
    let params = LlamaModelParams::default().with_n_gpu_layers(1_000);
    let model = LlamaModel::load_from_file(backend, model_path, &params)
        .map_err(|error| AdapterError::Process(format!("could not load LLM: {error}")))?;
    let n_ctx = llm_n_ctx(std::env::var("AFTERRAY_LLM_N_CTX").ok().as_deref());
    let n_batch = n_ctx.get().min(DEFAULT_N_BATCH);
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(Some(n_ctx))
        .with_n_batch(n_batch);
    let mut ctx = model
        .new_context(backend, ctx_params)
        .map_err(|error| AdapterError::Process(format!("LLM context failed: {error}")))?;

    let composed = compose_prompt(&model, prompt, system);
    let tokens = model
        .str_to_token(&composed, AddBos::Never)
        .map_err(|error| AdapterError::Process(format!("could not tokenize prompt: {error}")))?;
    if tokens.is_empty() {
        return Err(AdapterError::InvalidOutput(
            "LLM produced no prompt tokens".into(),
        ));
    }

    let batch_capacity = usize::try_from(n_batch).unwrap_or(512).max(1);
    let mut batch = LlamaBatch::new(batch_capacity, 1);
    let mut decoded = 0;
    while decoded < tokens.len() {
        batch.clear();
        let end = (decoded + batch_capacity).min(tokens.len());
        for (offset, token) in tokens[decoded..end].iter().enumerate() {
            let pos = decoded + offset;
            batch
                .add(
                    *token,
                    i32::try_from(pos).unwrap_or(0),
                    &[0],
                    pos + 1 == tokens.len(),
                )
                .map_err(|error| AdapterError::Process(format!("LLM batch failed: {error}")))?;
        }
        ctx.decode(&mut batch)
            .map_err(|error| AdapterError::Process(format!("LLM prefill failed: {error}")))?;
        decoded = end;
    }

    let mut sampler = LlamaSampler::greedy();
    let max_tokens = std::env::var("AFTERRAY_LLM_MAX_TOKENS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_MAX_TOKENS);
    let mut pieces = String::new();
    let mut decoder = encoding_rs::UTF_8.new_decoder();
    let mut n_cur = i32::try_from(tokens.len()).unwrap_or(0);
    let eos = model.token_eos();
    for _ in 0..max_tokens {
        let token = sampler.sample(&ctx, -1);
        sampler.accept(token);
        if token == eos || model.is_eog_token(token) {
            break;
        }
        let piece = model
            .token_to_piece(token, &mut decoder, false, None)
            .map_err(|error| AdapterError::Process(format!("LLM decode failed: {error}")))?;
        pieces.push_str(&piece);
        if pieces.contains(QWEN_IM_END) {
            break;
        }
        batch.clear();
        batch
            .add(token, n_cur, &[0], true)
            .map_err(|error| AdapterError::Process(format!("LLM batch failed: {error}")))?;
        n_cur += 1;
        ctx.decode(&mut batch)
            .map_err(|error| AdapterError::Process(format!("LLM decode failed: {error}")))?;
    }
    Ok(trim_generated(&pieces))
}

fn compose_prompt(model: &LlamaModel, prompt: &str, system: Option<&str>) -> String {
    match apply_builtin_chat_template(model, prompt, system) {
        Ok(text) if !text.is_empty() => text,
        _ => compose_qwen_chatml(prompt, system),
    }
}

fn apply_builtin_chat_template(
    model: &LlamaModel,
    prompt: &str,
    system: Option<&str>,
) -> Result<String, AdapterError> {
    let template = model
        .chat_template(None)
        .map_err(|error| AdapterError::Process(error.to_string()))?;
    let messages = chat_messages(prompt, system)?;
    model
        .apply_chat_template(&template, &messages, true)
        .map_err(|error| AdapterError::Process(format!("chat template failed: {error}")))
}

fn chat_messages(
    prompt: &str,
    system: Option<&str>,
) -> Result<Vec<LlamaChatMessage>, AdapterError> {
    let mut messages = Vec::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        messages.push(
            LlamaChatMessage::new("system".into(), system.to_owned())
                .map_err(|error| AdapterError::InvalidOutput(error.to_string()))?,
        );
    }
    messages.push(
        LlamaChatMessage::new("user".into(), prompt.to_owned())
            .map_err(|error| AdapterError::InvalidOutput(error.to_string()))?,
    );
    Ok(messages)
}

/// Qwen `ChatML` used when the GGUF has no built-in template. Compatible with
/// Qwen2.5-Instruct and Qwen3.6 instruct GGUFs.
#[must_use]
pub(crate) fn compose_qwen_chatml(prompt: &str, system: Option<&str>) -> String {
    let mut composed = String::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        composed.push_str(QWEN_IM_START);
        composed.push_str("system\n");
        composed.push_str(system);
        composed.push('\n');
        composed.push_str(QWEN_IM_END);
        composed.push('\n');
    }
    composed.push_str(QWEN_IM_START);
    composed.push_str("user\n");
    composed.push_str(prompt);
    composed.push('\n');
    composed.push_str(QWEN_IM_END);
    composed.push('\n');
    composed.push_str(QWEN_IM_START);
    composed.push_str("assistant\n");
    composed
}

#[must_use]
pub(crate) fn trim_generated(text: &str) -> String {
    let mut out = text;
    if let Some(index) = out.find(QWEN_IM_END) {
        out = &out[..index];
    }
    if let Some(index) = out.find(QWEN_IM_START) {
        out = &out[..index];
    }
    out.trim().to_owned()
}

#[must_use]
pub(crate) fn llm_n_ctx(raw: Option<&str>) -> NonZeroU32 {
    raw.and_then(|value| value.parse().ok())
        .and_then(NonZeroU32::new)
        .unwrap_or(NonZeroU32::new(DEFAULT_N_CTX).expect("default n_ctx is non-zero"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qwen_chatml_includes_system_user_and_assistant_prefix() {
        let prompt = compose_qwen_chatml("What did I just see?", Some("You are AfterRay."));
        assert_eq!(
            prompt,
            "<|im_start|>system\nYou are AfterRay.\n<|im_end|>\n<|im_start|>user\nWhat did I just see?\n<|im_end|>\n<|im_start|>assistant\n"
        );
    }

    #[test]
    fn qwen_chatml_skips_empty_system() {
        let prompt = compose_qwen_chatml("summarize this", None);
        assert!(!prompt.contains("system"));
        assert!(prompt.starts_with("<|im_start|>user\nsummarize this\n<|im_end|>\n"));
        assert!(prompt.ends_with("<|im_start|>assistant\n"));
    }

    #[test]
    fn generated_text_stops_at_im_end() {
        assert_eq!(
            trim_generated("Hello there<|im_end|>\n<|im_start|>user\n"),
            "Hello there"
        );
        assert_eq!(trim_generated("  just the answer  "), "just the answer");
    }

    #[test]
    fn n_ctx_defaults_to_16k_and_is_overridable() {
        assert_eq!(llm_n_ctx(None).get(), 16_384);
        assert_eq!(llm_n_ctx(Some("4096")).get(), 4_096);
        assert_eq!(llm_n_ctx(Some("0")).get(), 16_384);
        assert_eq!(llm_n_ctx(Some("nope")).get(), 16_384);
    }

    #[test]
    fn missing_weights_do_not_load_the_model() {
        let error = generate(Path::new("/tmp/afterray-missing-llm.gguf"), "hi", None).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("missing"), "{message}");
        assert!(message.contains("AFTERRAY_LLM_MODEL"), "{message}");
    }
}
