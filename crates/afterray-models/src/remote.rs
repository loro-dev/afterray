mod stream;

use crate::{
    AdapterError, Cancellation, ModelAdapter, ModelCapability, ModelInput, ModelOutput,
    PersistentMlxAdapter, QWEN35_4B_MLX_PACK_ID, QWEN35_9B_MLX_PACK_ID,
};
use afterray_protocol::{LlmEndpointStatus, LlmProvider, LlmRemoteModel};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::sync::mpsc;

pub use stream::{ollama_chat_delta, ollama_chat_url, openai_sse_delta};

pub const DEFAULT_OLLAMA_BASE_URL: &str = "http://127.0.0.1:11434";
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const GENERATE_TIMEOUT: Duration = Duration::from_secs(180);

const PREFERRED_CHAT_MODELS: &[&str] = &["qwen3.7", "qwen3.6", "qwen3.5", "qwen3", "qwen2.5"];

/// Runtime LLM routing. Shared with the daemon so Settings can change the
/// backend without rebuilding the model queue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LlmRuntimeConfig {
    pub provider: LlmProvider,
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
}

impl Default for LlmRuntimeConfig {
    fn default() -> Self {
        Self {
            provider: LlmProvider::MlxLocal,
            base_url: String::new(),
            model: String::new(),
            api_key: None,
        }
    }
}

impl LlmRuntimeConfig {
    /// `mlx_present` says whether the selected managed MLX pack is on disk;
    /// the remote providers only need a chat model to be chosen.
    #[must_use]
    pub fn is_ready(&self, mlx_present: bool) -> bool {
        match self.provider {
            LlmProvider::MlxLocal => mlx_present,
            LlmProvider::Ollama | LlmProvider::OpenaiCompatible => !self.chat_model().is_empty(),
        }
    }

    #[must_use]
    pub fn chat_model(&self) -> &str {
        self.model.trim()
    }

    /// MLX choices are managed pack IDs, never a free-form model path or
    /// remote repository. Empty settings retain the recommended 4B default.
    #[must_use]
    pub fn mlx_pack_id(&self) -> Option<&'static str> {
        match self.chat_model() {
            "" | QWEN35_4B_MLX_PACK_ID => Some(QWEN35_4B_MLX_PACK_ID),
            QWEN35_9B_MLX_PACK_ID => Some(QWEN35_9B_MLX_PACK_ID),
            _ => None,
        }
    }

    #[must_use]
    pub fn resolved_base_url(&self) -> String {
        let raw = self.base_url.trim();
        if !raw.is_empty() {
            return normalize_origin(raw);
        }
        match self.provider {
            LlmProvider::Ollama => DEFAULT_OLLAMA_BASE_URL.to_owned(),
            LlmProvider::MlxLocal | LlmProvider::OpenaiCompatible => String::new(),
        }
    }
}

/// Optional chat-only side channel. The next remote `execute` takes the
/// sender so a queued T2 job cannot keep the outlet after chat arms it.
#[derive(Clone, Default)]
pub struct LlmTokenSink {
    inner: Arc<std::sync::Mutex<Option<mpsc::Sender<String>>>>,
}

impl LlmTokenSink {
    /// Installs a sender until the guard drops. Chat holds the guard around
    /// `submit`/`wait` so tokens from that generation can leak out.
    #[must_use = "dropping the guard clears the token outlet"]
    pub fn install(&self, tx: mpsc::Sender<String>) -> LlmTokenSinkGuard {
        *self.lock() = Some(tx);
        LlmTokenSinkGuard {
            inner: Arc::clone(&self.inner),
        }
    }

    fn take(&self) -> Option<mpsc::Sender<String>> {
        self.lock().take()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<mpsc::Sender<String>>> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Clears the outlet even if the chat task is cancelled mid-wait.
pub struct LlmTokenSinkGuard {
    inner: Arc<std::sync::Mutex<Option<mpsc::Sender<String>>>>,
}

impl Drop for LlmTokenSinkGuard {
    fn drop(&mut self) {
        *self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }
}

/// Routes LLM jobs to a managed MLX worker on this Mac or an
/// OpenAI-compatible HTTP endpoint (Ollama included).
pub struct LlmRouterAdapter {
    mlx: BTreeMap<String, Arc<PersistentMlxAdapter>>,
    config: Arc<std::sync::Mutex<LlmRuntimeConfig>>,
    client: reqwest::Client,
    token_sink: LlmTokenSink,
}

impl LlmRouterAdapter {
    #[must_use]
    pub fn new(config: Arc<std::sync::Mutex<LlmRuntimeConfig>>) -> Self {
        Self {
            mlx: BTreeMap::new(),
            config,
            client: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(2))
                .timeout(GENERATE_TIMEOUT)
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
            token_sink: LlmTokenSink::default(),
        }
    }

    #[must_use]
    pub fn with_mlx(mut self, pack_id: impl Into<String>, mlx: Arc<PersistentMlxAdapter>) -> Self {
        self.mlx.insert(pack_id.into(), mlx);
        self
    }

    #[must_use]
    pub fn token_sink(&self) -> LlmTokenSink {
        self.token_sink.clone()
    }

    fn snapshot(&self) -> LlmRuntimeConfig {
        self.config
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

#[async_trait]
impl ModelAdapter for LlmRouterAdapter {
    fn capability(&self) -> ModelCapability {
        ModelCapability::Llm
    }

    fn name(&self) -> &str {
        match self.snapshot().provider {
            LlmProvider::MlxLocal => "mlx-local-llm",
            LlmProvider::Ollama => "ollama-llm",
            LlmProvider::OpenaiCompatible => "openai-llm",
        }
    }

    async fn execute(
        &self,
        job_id: &str,
        input: &ModelInput,
        cancellation: Cancellation,
    ) -> Result<ModelOutput, AdapterError> {
        if input.capability() != ModelCapability::Llm {
            return Err(AdapterError::InvalidOutput(format!(
                "LLM router does not handle {:?}",
                input.capability()
            )));
        }
        let config = self.snapshot();
        // Consume the outlet on every path so a later remote job cannot
        // inherit a chat sender that was never claimed.
        let token_tx = self.token_sink.take();
        match config.provider {
            LlmProvider::MlxLocal => {
                let pack_id = config.mlx_pack_id().ok_or_else(|| {
                    AdapterError::MissingModel(
                        "AfterRay MLX selection is invalid; choose the managed 4B or 9B pack".into(),
                    )
                })?;
                let mlx = self.mlx.get(pack_id).ok_or_else(|| {
                    AdapterError::MissingModel(
                        format!("AfterRay MLX worker for `{pack_id}` is unavailable in this installation"),
                    )
                })?;
                mlx.execute_streaming(job_id, input, token_tx, cancellation)
                    .await
            }
            LlmProvider::Ollama | LlmProvider::OpenaiCompatible => {
                let ModelInput::Llm { prompt, system } = input else {
                    return Err(AdapterError::InvalidOutput(
                        "LLM router received a non-LLM input".into(),
                    ));
                };
                let text = generate_remote(
                    &self.client,
                    &config,
                    prompt,
                    system.as_deref(),
                    token_tx,
                    cancellation,
                )
                .await?;
                Ok(ModelOutput::Llm { text })
            }
        }
    }
}

/// Probes Ollama or an OpenAI-compatible `/models` endpoint.
pub async fn probe_llm(
    provider: LlmProvider,
    base_url: Option<&str>,
    api_key: Option<&str>,
) -> LlmEndpointStatus {
    let default_base_url = match provider {
        LlmProvider::Ollama => DEFAULT_OLLAMA_BASE_URL.to_owned(),
        LlmProvider::MlxLocal => String::new(),
        LlmProvider::OpenaiCompatible => base_url
            .map(normalize_origin)
            .filter(|value| !value.is_empty())
            .unwrap_or_default(),
    };
    if matches!(provider, LlmProvider::MlxLocal) {
        return LlmEndpointStatus {
            reachable: false,
            models: Vec::new(),
            recommended_model: None,
            error: None,
            default_base_url,
        };
    }
    let origin = base_url
        .map(normalize_origin)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default_base_url.clone());
    if origin.is_empty() {
        return LlmEndpointStatus {
            reachable: false,
            models: Vec::new(),
            recommended_model: None,
            error: Some("set an OpenAI-compatible base URL first".into()),
            default_base_url,
        };
    }

    let client = match reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(2))
        .timeout(PROBE_TIMEOUT)
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            return LlmEndpointStatus {
                reachable: false,
                models: Vec::new(),
                recommended_model: None,
                error: Some(error.to_string()),
                default_base_url,
            };
        }
    };

    let result = match provider {
        LlmProvider::Ollama => probe_ollama(&client, &origin).await,
        LlmProvider::OpenaiCompatible => probe_openai(&client, &origin, api_key).await,
        LlmProvider::MlxLocal => unreachable!("local probe returns earlier"),
    };
    match result {
        Ok(models) => {
            let recommended_model = recommend_model(models.iter().map(|model| model.id.as_str()));
            LlmEndpointStatus {
                reachable: true,
                models,
                recommended_model,
                error: None,
                default_base_url: origin,
            }
        }
        Err(error) => LlmEndpointStatus {
            reachable: false,
            models: Vec::new(),
            recommended_model: None,
            error: Some(error),
            default_base_url: origin,
        },
    }
}

async fn probe_ollama(
    client: &reqwest::Client,
    origin: &str,
) -> Result<Vec<LlmRemoteModel>, String> {
    let tags_url = ollama_tags_url(origin);
    match get_json(client, &tags_url, None).await {
        Ok(value) => Ok(models_from_ollama_tags(&value)),
        Err(tags_error) => {
            let models_url = openai_models_url(origin);
            match get_json(client, &models_url, None).await {
                Ok(value) => Ok(models_from_openai_list(&value)),
                Err(_) => Err(format!(
                    "could not reach Ollama at {origin}; start Ollama or pick another assistant source. {tags_error}"
                )),
            }
        }
    }
}

async fn probe_openai(
    client: &reqwest::Client,
    origin: &str,
    api_key: Option<&str>,
) -> Result<Vec<LlmRemoteModel>, String> {
    let url = openai_models_url(origin);
    let value = get_json(client, &url, api_key).await?;
    Ok(models_from_openai_list(&value))
}

async fn generate_remote(
    client: &reqwest::Client,
    config: &LlmRuntimeConfig,
    prompt: &str,
    system: Option<&str>,
    token_tx: Option<mpsc::Sender<String>>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    if let Some(token_tx) = token_tx {
        return stream::generate_streaming(client, config, prompt, system, token_tx, cancellation)
            .await;
    }
    let model = config.chat_model();
    if model.is_empty() {
        return Err(AdapterError::MissingModel(
            "no remote LLM model is configured; pick one in Settings".into(),
        ));
    }
    let origin = config.resolved_base_url();
    if origin.is_empty() {
        return Err(AdapterError::MissingModel(
            "OpenAI-compatible URL is empty; set it in Settings".into(),
        ));
    }
    let url = chat_completions_url(&origin);
    let mut messages = Vec::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        messages.push(json!({"role": "system", "content": system}));
    }
    messages.push(json!({"role": "user", "content": prompt}));
    let body = json!({
        "model": model,
        "messages": messages,
        "stream": false,
    });

    let mut request = client.post(&url).json(&body);
    if let Some(api_key) = config
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        request = request.bearer_auth(api_key);
    }

    let response = tokio::select! {
        () = cancellation.cancelled() => return Err(AdapterError::Cancelled),
        result = request.send() => result.map_err(|error| {
            AdapterError::Process(format!("could not reach {url}: {error}"))
        })?,
    };
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|error| AdapterError::Process(format!("LLM response body failed: {error}")))?;
    if !status.is_success() {
        return Err(remote_http_error(status.as_u16(), &text, model));
    }
    let value: Value = serde_json::from_str(&text)
        .map_err(|error| AdapterError::InvalidOutput(format!("LLM returned non-JSON: {error}")))?;
    chat_message_content(&value).ok_or_else(|| {
        AdapterError::InvalidOutput("OpenAI-compatible response had no assistant text".into())
    })
}

pub(crate) fn remote_http_error(status: u16, body: &str, model: &str) -> AdapterError {
    let preview = truncate(body.trim(), 400);
    match status {
        401 | 403 => AdapterError::Process(format!(
            "OpenAI-compatible endpoint returned {status}; check the API key. {preview}"
        )),
        404 => AdapterError::MissingModel(format!(
            "model `{model}` was not found; pick an installed model in Settings. {preview}"
        )),
        _ => AdapterError::Process(format!(
            "OpenAI-compatible endpoint returned {status}. {preview}"
        )),
    }
}

async fn get_json(
    client: &reqwest::Client,
    url: &str,
    api_key: Option<&str>,
) -> Result<Value, String> {
    let mut request = client.get(url);
    if let Some(api_key) = api_key.map(str::trim).filter(|value| !value.is_empty()) {
        request = request.bearer_auth(api_key);
    }
    let response = request
        .send()
        .await
        .map_err(|error| format!("could not reach {url}: {error}"))?;
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|error| format!("could not read {url}: {error}"))?;
    if !status.is_success() {
        return Err(format!("{url} returned {status}: {}", truncate(&text, 240)));
    }
    serde_json::from_str(&text).map_err(|error| format!("{url} returned non-JSON: {error}"))
}

#[must_use]
pub fn normalize_origin(raw: &str) -> String {
    raw.trim().trim_end_matches('/').to_owned()
}

#[must_use]
pub fn chat_completions_url(origin: &str) -> String {
    let origin = normalize_origin(origin);
    if origin.ends_with("/chat/completions") {
        origin
    } else if origin.ends_with("/v1") {
        format!("{origin}/chat/completions")
    } else {
        format!("{origin}/v1/chat/completions")
    }
}

#[must_use]
pub fn openai_models_url(origin: &str) -> String {
    let origin = normalize_origin(origin);
    if origin.ends_with("/models") {
        origin
    } else if origin.ends_with("/v1") {
        format!("{origin}/models")
    } else {
        format!("{origin}/v1/models")
    }
}

#[must_use]
pub fn ollama_tags_url(origin: &str) -> String {
    let origin = normalize_origin(origin);
    let host = origin.strip_suffix("/v1").unwrap_or(origin.as_str());
    format!("{host}/api/tags")
}

#[must_use]
pub fn recommend_model<'a, I>(ids: I) -> Option<String>
where
    I: IntoIterator<Item = &'a str>,
{
    let ids: Vec<String> = ids
        .into_iter()
        .map(str::trim)
        .filter(|id| !id.is_empty() && !is_embedding_model(id))
        .map(ToOwned::to_owned)
        .collect();
    for preferred in PREFERRED_CHAT_MODELS {
        if let Some(id) = ids.iter().find(|id| model_matches(id, preferred)) {
            return Some(id.clone());
        }
    }
    ids.into_iter().next()
}

#[must_use]
pub fn models_from_ollama_tags(value: &Value) -> Vec<LlmRemoteModel> {
    value
        .get("models")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let id = entry
                .get("name")
                .or_else(|| entry.get("model"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())?;
            if is_embedding_only_ollama(entry, id) {
                return None;
            }
            Some(LlmRemoteModel {
                id: id.to_owned(),
                name: id.to_owned(),
            })
        })
        .collect()
}

#[must_use]
pub fn models_from_openai_list(value: &Value) -> Vec<LlmRemoteModel> {
    value
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let id = entry
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|id| !id.is_empty())?;
            if is_embedding_model(id) {
                return None;
            }
            Some(LlmRemoteModel {
                id: id.to_owned(),
                name: id.to_owned(),
            })
        })
        .collect()
}

fn chat_message_content(value: &Value) -> Option<String> {
    let content = value.pointer("/choices/0/message/content")?;
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| {
                part.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| part.as_str())
            })
            .collect::<Vec<_>>()
            .join(""),
        _ => return None,
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn is_embedding_only_ollama(entry: &Value, id: &str) -> bool {
    if is_embedding_model(id) {
        return true;
    }
    let Some(capabilities) = entry.get("capabilities").and_then(Value::as_array) else {
        return false;
    };
    let labels: Vec<_> = capabilities.iter().filter_map(Value::as_str).collect();
    !labels.is_empty() && labels.iter().all(|label| *label == "embedding")
}

fn is_embedding_model(id: &str) -> bool {
    let lower = id.to_ascii_lowercase();
    lower.contains("embed") || lower.contains("nomic-embed")
}

fn model_matches(id: &str, preferred: &str) -> bool {
    let lower = id.to_ascii_lowercase();
    lower == preferred
        || lower.starts_with(&format!("{preferred}:"))
        || lower.starts_with(&format!("{preferred}-"))
}

fn truncate(text: &str, max_chars: usize) -> String {
    let count = text.chars().count();
    if count <= max_chars {
        return text.to_owned();
    }
    let taken: String = text.chars().take(max_chars.saturating_sub(1)).collect();
    format!("{taken}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mlx_is_the_default_and_is_ready_only_with_the_verified_pack() {
        let config = LlmRuntimeConfig::default();
        assert_eq!(config.provider, LlmProvider::MlxLocal);
        assert!(!config.is_ready(false));
        assert!(config.is_ready(true));
        assert!(config.resolved_base_url().is_empty());
    }

    #[test]
    fn remote_is_ready_when_model_is_set() {
        let mut config = LlmRuntimeConfig {
            provider: LlmProvider::Ollama,
            ..LlmRuntimeConfig::default()
        };
        assert!(!config.is_ready(false));
        config.model = "qwen3.6:latest".into();
        assert!(config.is_ready(false));
        assert_eq!(config.resolved_base_url(), DEFAULT_OLLAMA_BASE_URL);
    }

    #[test]
    fn openai_url_requires_user_value() {
        let config = LlmRuntimeConfig {
            provider: LlmProvider::OpenaiCompatible,
            model: "qwen3.7-max".into(),
            ..LlmRuntimeConfig::default()
        };
        assert!(config.resolved_base_url().is_empty());
        let configured = LlmRuntimeConfig {
            provider: LlmProvider::OpenaiCompatible,
            base_url: "https://example.test/v1/".into(),
            model: "qwen3.7-max".into(),
            ..LlmRuntimeConfig::default()
        };
        assert_eq!(configured.resolved_base_url(), "https://example.test/v1");
    }

    #[test]
    fn completion_urls_normalize_v1_and_origin() {
        assert_eq!(
            chat_completions_url("http://127.0.0.1:11434"),
            "http://127.0.0.1:11434/v1/chat/completions"
        );
        assert_eq!(
            chat_completions_url("http://127.0.0.1:11434/v1/"),
            "http://127.0.0.1:11434/v1/chat/completions"
        );
        assert_eq!(
            openai_models_url("https://api.example/v1"),
            "https://api.example/v1/models"
        );
        assert_eq!(
            ollama_tags_url("http://127.0.0.1:11434/v1"),
            "http://127.0.0.1:11434/api/tags"
        );
    }

    #[test]
    fn ollama_tags_skip_embedding_only_models() {
        let value = json!({
            "models": [
                {
                    "name": "nomic-embed-text:latest",
                    "capabilities": ["embedding"]
                },
                {
                    "name": "qwen3.6:latest",
                    "capabilities": ["completion", "tools"]
                },
                {
                    "name": "qwen2.5vl:3b",
                    "capabilities": ["vision", "completion"]
                }
            ]
        });
        let models = models_from_ollama_tags(&value);
        let ids: Vec<_> = models.iter().map(|model| model.id.as_str()).collect();
        assert_eq!(ids, ["qwen3.6:latest", "qwen2.5vl:3b"]);
        assert_eq!(
            recommend_model(ids.iter().copied()).as_deref(),
            Some("qwen3.6:latest")
        );
    }

    #[test]
    fn openai_list_skips_embed_ids() {
        let value = json!({
            "data": [
                {"id": "text-embedding-3-small"},
                {"id": "qwen3.7-max"}
            ]
        });
        let models = models_from_openai_list(&value);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "qwen3.7-max");
        assert_eq!(
            recommend_model(["qwen3.7-max"]).as_deref(),
            Some("qwen3.7-max")
        );
    }

    #[test]
    fn chat_content_accepts_string_or_parts() {
        let string = json!({"choices":[{"message":{"content":"  hello  "}}]});
        assert_eq!(chat_message_content(&string).as_deref(), Some("hello"));
        let parts = json!({
            "choices":[{"message":{"content":[{"type":"text","text":"hi "},{"type":"text","text":"there"}]}}]
        });
        assert_eq!(chat_message_content(&parts).as_deref(), Some("hi there"));
    }

    /// A failed route must still claim the outlet, or the next queued job
    /// would inherit a chat sender that was never meant for it.
    #[tokio::test]
    async fn a_failed_route_consumes_the_token_sink() {
        let adapter = LlmRouterAdapter::new(Arc::new(std::sync::Mutex::new(
            LlmRuntimeConfig::default(),
        )));
        let sink = adapter.token_sink();
        let (tx, mut rx) = tokio::sync::mpsc::channel(8);
        let _guard = sink.install(tx);
        let error = adapter
            .execute(
                "job-1",
                &ModelInput::Llm {
                    prompt: "hi".into(),
                    system: None,
                },
                Cancellation::default(),
            )
            .await
            .expect_err("no MLX worker is registered on this router");
        assert!(matches!(error, AdapterError::MissingModel(_)));
        assert!(rx.try_recv().is_err());
        assert!(
            sink.take().is_none(),
            "the outlet must be consumed so a later job cannot inherit it"
        );
    }
}
