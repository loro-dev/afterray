//! Remote token streaming used only by the chat path.
//!
//! `ModelQueue` still waits for a complete `ModelOutput`. These helpers
//! optionally copy token deltas onto a side channel while that full text
//! is assembled, so a client can render incrementally without a second
//! generation.

use super::{LlmRuntimeConfig, chat_completions_url, normalize_origin, remote_http_error};
use crate::{AdapterError, Cancellation, ChatMessage, LlmDelta};
use futures_util::StreamExt as _;
use serde_json::{Value, json};
use tokio::sync::mpsc;

/// Ollama native chat endpoint. `/v1` is stripped so a Settings URL that
/// was stored for the OpenAI-compatible path still hits `/api/chat`.
#[must_use]
pub fn ollama_chat_url(origin: &str) -> String {
    let origin = normalize_origin(origin);
    let host = origin.strip_suffix("/v1").unwrap_or(origin.as_str());
    if host.ends_with("/api/chat") {
        host.to_owned()
    } else {
        format!("{host}/api/chat")
    }
}

pub(super) async fn generate_streaming(
    client: &reqwest::Client,
    config: &LlmRuntimeConfig,
    prompt: &str,
    messages: &[ChatMessage],
    system: Option<&str>,
    token_tx: mpsc::Sender<LlmDelta>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    let body = chat_messages(prompt, messages, system);
    match config.provider {
        afterray_protocol::LlmProvider::Ollama => {
            generate_ollama_stream(client, config, body, token_tx, cancellation).await
        }
        afterray_protocol::LlmProvider::OpenaiCompatible => {
            generate_openai_stream(client, config, body, token_tx, cancellation).await
        }
        afterray_protocol::LlmProvider::MlxLocal => Err(AdapterError::InvalidOutput(
            "MLX local generation uses the persistent worker protocol".into(),
        )),
    }
}

async fn generate_ollama_stream(
    client: &reqwest::Client,
    config: &LlmRuntimeConfig,
    messages: Vec<Value>,
    token_tx: mpsc::Sender<LlmDelta>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    let model = require_model(config)?;
    let origin = require_origin(config)?;
    let url = ollama_chat_url(&origin);
    let mut body = json!({
        "model": model,
        "messages": messages,
        "stream": true,
    });
    // Declaring the window makes the server's own default stop mattering: left
    // alone it picks from installed RAM and cuts anything longer without a
    // word. The value has to be the one the harness budgeted against — it sizes
    // a KV cache in the same memory the rest of the machine is using, so this
    // is not a place to ask for the maximum and hope.
    if let Some(num_ctx) = config.context_tokens {
        body["options"] = json!({ "num_ctx": num_ctx });
    }
    let response = send_chat(client, &url, None, &body, &cancellation).await?;
    let status = response.status();
    if !status.is_success() {
        let text = response_text(response).await?;
        return Err(remote_http_error(status.as_u16(), &text, model));
    }
    fold_lines(response, cancellation, &token_tx, ollama_chat_delta).await
}

async fn generate_openai_stream(
    client: &reqwest::Client,
    config: &LlmRuntimeConfig,
    messages: Vec<Value>,
    token_tx: mpsc::Sender<LlmDelta>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    let model = require_model(config)?;
    let origin = require_origin(config)?;
    let url = chat_completions_url(&origin);
    let body = json!({
        "model": model,
        "messages": messages,
        "stream": true,
    });
    let api_key = config
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let response = send_chat(client, &url, api_key, &body, &cancellation).await?;
    let status = response.status();
    if !status.is_success() {
        let text = response_text(response).await?;
        return Err(remote_http_error(status.as_u16(), &text, model));
    }
    fold_lines(response, cancellation, &token_tx, openai_sse_delta).await
}

fn require_model(config: &LlmRuntimeConfig) -> Result<&str, AdapterError> {
    let model = config.chat_model();
    if model.is_empty() {
        return Err(AdapterError::MissingModel(
            "no remote LLM model is configured; pick one in Settings".into(),
        ));
    }
    Ok(model)
}

fn require_origin(config: &LlmRuntimeConfig) -> Result<String, AdapterError> {
    let origin = config.resolved_base_url();
    if origin.is_empty() {
        return Err(AdapterError::MissingModel(
            "OpenAI-compatible URL is empty; set it in Settings".into(),
        ));
    }
    Ok(origin)
}

/// The outgoing `messages` array.
///
/// A conversation when the caller has one, and a single user turn when it does
/// not. The two-message shape was the only shape for a long time, which is what
/// made the prefix unstable: an entire conversation folded into one string,
/// re-sliced every turn, so nothing a provider had cached ever matched.
fn chat_messages(prompt: &str, messages: &[ChatMessage], system: Option<&str>) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        out.push(json!({"role": "system", "content": system}));
    }
    if messages.is_empty() {
        out.push(json!({"role": "user", "content": prompt}));
        return out;
    }
    out.extend(
        messages
            .iter()
            .map(|message| json!({"role": message.role, "content": message.content})),
    );
    out
}

async fn send_chat(
    client: &reqwest::Client,
    url: &str,
    api_key: Option<&str>,
    body: &Value,
    cancellation: &Cancellation,
) -> Result<reqwest::Response, AdapterError> {
    let mut request = client.post(url).json(body);
    if let Some(api_key) = api_key {
        request = request.bearer_auth(api_key);
    }
    tokio::select! {
        () = cancellation.cancelled() => Err(AdapterError::Cancelled),
        result = request.send() => result.map_err(|error| {
            AdapterError::Process(format!("could not reach {url}: {error}"))
        }),
    }
}

async fn response_text(response: reqwest::Response) -> Result<String, AdapterError> {
    response
        .text()
        .await
        .map_err(|error| AdapterError::Process(format!("LLM response body failed: {error}")))
}

async fn fold_lines(
    response: reqwest::Response,
    cancellation: Cancellation,
    token_tx: &mpsc::Sender<LlmDelta>,
    parse_line: fn(&str) -> Option<LlmDelta>,
) -> Result<String, AdapterError> {
    let mut stream = response.bytes_stream();
    let mut pending = Vec::new();
    let mut assembled = String::new();
    loop {
        let chunk = tokio::select! {
            () = cancellation.cancelled() => return Err(AdapterError::Cancelled),
            next = stream.next() => next,
        };
        let Some(chunk) = chunk else {
            break;
        };
        let chunk = chunk
            .map_err(|error| AdapterError::Process(format!("LLM stream ended early: {error}")))?;
        pending.extend_from_slice(&chunk);
        drain_complete_lines(&mut pending, &mut assembled, token_tx, parse_line).await;
    }
    if !pending.is_empty() {
        let line = String::from_utf8_lossy(&pending);
        if !line.trim().is_empty() {
            push_delta(&mut assembled, token_tx, parse_line(line.as_ref())).await;
        }
    }
    if assembled.trim().is_empty() {
        return Err(AdapterError::InvalidOutput(
            "streamed chat response had no assistant text".into(),
        ));
    }
    Ok(assembled)
}

async fn drain_complete_lines(
    pending: &mut Vec<u8>,
    assembled: &mut String,
    token_tx: &mpsc::Sender<LlmDelta>,
    parse_line: fn(&str) -> Option<LlmDelta>,
) {
    while let Some(idx) = pending.iter().position(|&byte| byte == b'\n') {
        let mut line = pending.drain(..=idx).collect::<Vec<_>>();
        line.pop();
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        let line = String::from_utf8_lossy(&line);
        push_delta(assembled, token_tx, parse_line(line.as_ref())).await;
    }
}

/// Forwards one delta, and assembles only the ones that are the answer.
///
/// Reasoning never reaches `assembled`. That string is both the returned
/// completion and what `parse_final` / `parse_tool_call` read, so folding
/// scratch work into it would put the model's thinking in the chat window and
/// let a stray "FINAL" inside a reasoning block end the turn.
async fn push_delta(
    assembled: &mut String,
    token_tx: &mpsc::Sender<LlmDelta>,
    delta: Option<LlmDelta>,
) {
    let Some(delta) = delta.filter(|delta| !delta.text.is_empty()) else {
        return;
    };
    if delta.is_content() {
        assembled.push_str(&delta.text);
    }
    let _ = token_tx.send(delta).await;
}

/// One Ollama `/api/chat` JSON line, as answer text or as reasoning.
///
/// Ollama puts reasoning in `message.thinking` and leaves `message.content`
/// empty for the whole thinking phase, so reading content alone yields nothing
/// at all until the model is done deliberating.
#[must_use]
pub fn ollama_chat_delta(line: &str) -> Option<LlmDelta> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    if let Some(text) = json_text(value.pointer("/message/content")) {
        return Some(LlmDelta::content(text));
    }
    json_text(value.pointer("/message/thinking")).map(LlmDelta::reasoning)
}

/// One OpenAI-compatible SSE `data:` line, as answer text or as reasoning.
///
/// There is no standard field for reasoning, so both spellings in the wild are
/// accepted: `reasoning_content` (`DeepSeek`, and `vLLM`/`SGLang` serving Qwen) and
/// `reasoning` (`OpenRouter`, and several gateways). An endpoint that sends
/// neither simply never yields a reasoning delta.
#[must_use]
pub fn openai_sse_delta(line: &str) -> Option<LlmDelta> {
    let line = line.trim();
    let payload = line.strip_prefix("data:")?.trim();
    if payload.is_empty() || payload == "[DONE]" {
        return None;
    }
    let value: Value = serde_json::from_str(payload).ok()?;
    if let Some(text) = json_text(value.pointer("/choices/0/delta/content")) {
        return Some(LlmDelta::content(text));
    }
    json_text(value.pointer("/choices/0/delta/reasoning_content"))
        .or_else(|| json_text(value.pointer("/choices/0/delta/reasoning")))
        .map(LlmDelta::reasoning)
}

fn json_text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Array(parts) => {
            let text: String = parts
                .iter()
                .filter_map(|part| {
                    part.get("text")
                        .and_then(Value::as_str)
                        .or_else(|| part.as_str())
                })
                .collect();
            if text.is_empty() { None } else { Some(text) }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_protocol::LlmProvider;
    use crate::DEFAULT_OLLAMA_BASE_URL;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    use tokio::net::TcpListener;

    #[test]
    fn ollama_chat_url_strips_v1() {
        assert_eq!(
            ollama_chat_url("http://127.0.0.1:11434"),
            "http://127.0.0.1:11434/api/chat"
        );
        assert_eq!(
            ollama_chat_url("http://127.0.0.1:11434/v1"),
            "http://127.0.0.1:11434/api/chat"
        );
        assert_eq!(
            ollama_chat_url("http://127.0.0.1:11434/api/chat"),
            "http://127.0.0.1:11434/api/chat"
        );
    }

    #[test]
    fn ollama_line_prefers_content_over_thinking() {
        assert_eq!(
            ollama_chat_delta(
                r#"{"message":{"role":"assistant","content":"你","thinking":"hmm"},"done":false}"#
            ),
            Some(LlmDelta::content("你"))
        );
        assert!(
            ollama_chat_delta(r#"{"message":{"role":"assistant","content":""},"done":true}"#)
                .is_none()
        );
        assert!(ollama_chat_delta("not-json").is_none());
    }

    /// What a thinking model actually sends. Measured on `qwen3.6:35b-mlx`:
    /// 131 of these, then one content delta. Reading content alone yields
    /// nothing for the whole thinking phase, which is the dead air this
    /// labelling exists to end.
    #[test]
    fn ollama_line_reports_thinking_as_reasoning() {
        assert_eq!(
            ollama_chat_delta(
                r#"{"message":{"role":"assistant","content":"","thinking":"Here"},"done":false}"#
            ),
            Some(LlmDelta::reasoning("Here"))
        );
    }

    #[test]
    fn openai_sse_takes_delta_content() {
        assert_eq!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"content":"今"}}]}"#),
            Some(LlmDelta::content("今"))
        );
        assert!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#).is_none()
        );
        assert!(openai_sse_delta("data: [DONE]").is_none());
        assert!(openai_sse_delta("event: message").is_none());
    }

    /// There is no standard field, so both spellings in the wild are accepted:
    /// `reasoning_content` from `DeepSeek` and `vLLM`, `reasoning` from `OpenRouter`
    /// and several gateways.
    #[test]
    fn openai_sse_accepts_both_spellings_of_reasoning() {
        assert_eq!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"reasoning_content":"step"}}]}"#),
            Some(LlmDelta::reasoning("step"))
        );
        assert_eq!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"reasoning":"step"}}]}"#),
            Some(LlmDelta::reasoning("step"))
        );
        // Content still wins when an endpoint sends both on one line.
        assert_eq!(
            openai_sse_delta(
                r#"data: {"choices":[{"delta":{"content":"A","reasoning":"why"}}]}"#
            ),
            Some(LlmDelta::content("A"))
        );
    }

    /// Reasoning must never reach the assembled completion. That string is both
    /// the returned answer and what the loop parses, so a stray "FINAL" inside
    /// a reasoning block would end the turn on the model's scratch work.
    #[tokio::test]
    async fn reasoning_streams_but_never_joins_the_answer() {
        let body = concat!(
            r#"{"message":{"content":"","thinking":"FINAL nonsense"},"done":false}"#,
            "\n",
            r#"{"message":{"content":"OK"},"done":false}"#,
            "\n",
            r#"{"message":{"content":""},"done":true}"#,
            "\n",
        );
        let origin = serve_http(body, "application/x-ndjson").await;
        let (text, deltas) =
            generate_against(LlmProvider::Ollama, &origin, Cancellation::default())
                .await
                .unwrap();
        assert_eq!(text, "OK");
        assert_eq!(
            deltas,
            vec![LlmDelta::reasoning("FINAL nonsense"), LlmDelta::content("OK")]
        );
    }

    #[tokio::test]
    async fn ollama_ndjson_stream_forwards_tokens() {
        let body = concat!(
            r#"{"message":{"content":"你"},"done":false}"#,
            "\n",
            r#"{"message":{"content":"好"},"done":false}"#,
            "\n",
            r#"{"message":{"content":""},"done":true}"#,
            "\n",
        );
        let origin = serve_http(body, "application/x-ndjson").await;
        let (text, tokens) =
            generate_against(LlmProvider::Ollama, &origin, Cancellation::default())
                .await
                .unwrap();
        assert_eq!(text, "你好");
        assert_eq!(tokens, [LlmDelta::content("你"), LlmDelta::content("好")]);
    }

    #[tokio::test]
    async fn openai_sse_stream_forwards_tokens() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n",
            "data: [DONE]\n\n",
        );
        let origin = serve_http(body, "text/event-stream").await;
        let (text, tokens) = generate_against(
            LlmProvider::OpenaiCompatible,
            &origin,
            Cancellation::default(),
        )
        .await
        .unwrap();
        assert_eq!(text, "hello");
        assert_eq!(tokens, [LlmDelta::content("hel"), LlmDelta::content("lo")]);
    }

    #[tokio::test]
    async fn cancel_stops_a_slow_stream() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0_u8; 2048];
            let _ = socket.read(&mut buf).await;
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n";
            socket.write_all(header.as_bytes()).await.unwrap();
            socket
                .write_all(br#"{"message":{"content":"x"},"done":false}"#)
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let cancellation = Cancellation::default();
        let cancel = cancellation.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(40)).await;
            cancel.cancel();
        });
        let error = generate_against(LlmProvider::Ollama, &format!("http://{addr}"), cancellation)
            .await
            .unwrap_err();
        assert!(matches!(error, AdapterError::Cancelled));
    }

    /// Tag to use when this machine has it. A preference, never a requirement:
    /// see [`live_ollama_chat_model`] for why hardcoding one was the bug.
    const PREFERRED_OLLAMA_TEST_MODEL: &str = "qwen3.6:35b-mlx";

    /// A live Ollama chat model to run the streaming test against, or `None`
    /// when this machine cannot run it.
    ///
    /// The old guard checked only that the server answered, then used a
    /// hardcoded tag. That made the two skip-worthy states asymmetric:
    /// "Ollama is not running" returned quietly, while "Ollama is running but
    /// does not have this exact tag" was a hard failure — and the second is by
    /// far the more common, because nothing makes any machine pull whichever
    /// tag happened to be written here. Substituting a different hardcoded tag
    /// would only move that failure.
    ///
    /// Selection, in order:
    /// 1. `AFTERRAY_OLLAMA_TEST_MODEL`, so CI or another machine can pin one.
    /// 2. [`PREFERRED_OLLAMA_TEST_MODEL`], if installed.
    /// 3. Any installed model that serves `/api/chat`.
    async fn live_ollama_chat_model(client: &reqwest::Client) -> Option<String> {
        if let Ok(pinned) = std::env::var("AFTERRAY_OLLAMA_TEST_MODEL") {
            let pinned = pinned.trim();
            if !pinned.is_empty() {
                return Some(pinned.to_owned());
            }
        }
        let response = client
            .get(format!("{DEFAULT_OLLAMA_BASE_URL}/api/tags"))
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let body: Value = response.json().await.ok()?;
        pick_ollama_chat_model(body.get("models")?.as_array()?)
    }

    /// The selection itself, over an `/api/tags` `models` array.
    ///
    /// Split out from the HTTP call so it stays covered on a machine with no
    /// Ollama — which is most of them, and is exactly the machine where a
    /// mistake here turns back into a hard failure.
    fn pick_ollama_chat_model(models: &[Value]) -> Option<String> {
        let installed: Vec<&str> = models
            .iter()
            .filter(|model| ollama_model_serves_chat(model))
            .filter_map(|model| model.get("name").and_then(Value::as_str))
            .collect();
        installed
            .iter()
            .find(|name| **name == PREFERRED_OLLAMA_TEST_MODEL)
            .or_else(|| installed.first())
            .map(|name| (*name).to_owned())
    }

    /// Whether one `/api/tags` entry can answer `/api/chat`.
    ///
    /// Embedding models are excluded: they have no `/api/chat`, so picking one
    /// would reproduce the same hard failure under a different name.
    fn ollama_model_serves_chat(model: &Value) -> bool {
        match model.get("capabilities").and_then(Value::as_array) {
            Some(capabilities) => capabilities
                .iter()
                .any(|capability| capability.as_str() == Some("completion")),
            // Older servers omit `capabilities`. Fall back to the name, which
            // is what actually marks an embedding model in practice.
            None => !model
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .contains("embed"),
        }
    }

    /// The real `/api/tags` payload from the machine this was fixed on, cut to
    /// the fields that matter. `qwen3.6:latest` — the tag that used to be
    /// hardcoded — is deliberately absent, because that is the whole point.
    fn tags_fixture() -> Vec<Value> {
        serde_json::from_str(
            r#"[
              {"name":"qwen3.5:4b","capabilities":["vision","completion","tools","thinking"]},
              {"name":"nomic-embed-text:latest","capabilities":["embedding"]},
              {"name":"qwen3.6:35b-mlx","capabilities":["completion","vision","thinking","tools"]},
              {"name":"gemma4:latest","capabilities":["completion","tools","thinking"]}
            ]"#,
        )
        .unwrap()
    }

    #[test]
    fn model_choice_prefers_the_known_good_tag() {
        assert_eq!(
            pick_ollama_chat_model(&tags_fixture()).as_deref(),
            Some(PREFERRED_OLLAMA_TEST_MODEL)
        );
    }

    /// Without the preferred tag, any chat model will do. Hardcoding a second
    /// tag here would only move the original failure.
    #[test]
    fn model_choice_falls_back_to_any_chat_model() {
        let models: Vec<Value> = tags_fixture()
            .into_iter()
            .filter(|model| model["name"] != PREFERRED_OLLAMA_TEST_MODEL)
            .collect();
        assert_eq!(
            pick_ollama_chat_model(&models).as_deref(),
            Some("qwen3.5:4b")
        );
    }

    /// An embedding model has no `/api/chat`. Choosing one would reproduce the
    /// hard failure this guard exists to remove.
    #[test]
    fn model_choice_never_returns_an_embedding_model() {
        let embedding_only: Vec<Value> = serde_json::from_str(
            r#"[{"name":"nomic-embed-text:latest","capabilities":["embedding"]}]"#,
        )
        .unwrap();
        assert_eq!(pick_ollama_chat_model(&embedding_only), None);
        assert!(pick_ollama_chat_model(&[]).is_none());
    }

    /// Older servers omit `capabilities` entirely; the name is then the only
    /// signal, and it must still keep embedding models out.
    #[test]
    fn model_choice_copes_with_a_server_that_reports_no_capabilities() {
        let legacy: Vec<Value> =
            serde_json::from_str(r#"[{"name":"nomic-embed-text:latest"},{"name":"llama3:8b"}]"#)
                .unwrap();
        assert_eq!(pick_ollama_chat_model(&legacy).as_deref(), Some("llama3:8b"));
    }

    #[tokio::test]
    async fn live_ollama_streams_tokens_when_running() {
        let probe = reqwest::Client::builder()
            .timeout(Duration::from_secs(8))
            .build()
            .unwrap();
        let Some(model) = live_ollama_chat_model(&probe).await else {
            // Said out loud. This is the only check that the live Ollama
            // `/api/chat` NDJSON parse works against a real server, and a test
            // that skips silently forever is the same as no test at all.
            eprintln!(
                "skip: no live Ollama chat model on {DEFAULT_OLLAMA_BASE_URL} \
                 (set AFTERRAY_OLLAMA_TEST_MODEL to pin one)"
            );
            return;
        };
        eprintln!("live ollama /api/chat stream test using model `{model}`");
        let mut config = LlmRuntimeConfig {
            provider: LlmProvider::Ollama,
            base_url: String::new(),
            model,
            api_key: None,
            context_tokens: None,
        };
        // The probe against a real server, and the value that then goes out as
        // `num_ctx`. Printed because the interesting part is the disagreement
        // between the four inputs, which no fixture can reproduce.
        let context = crate::probe_context_tokens(&config, 262_144).await;
        eprintln!(
            "live ollama {} -> declaring num_ctx={}",
            context.summary(),
            context.resolved
        );
        assert!(
            context.resolved >= crate::MINIMUM_CONTEXT_TOKENS,
            "a live probe should not resolve below the floor: {context:?}"
        );
        config.context_tokens = Some(context.resolved);
        let (tx, mut rx) = mpsc::channel(32);
        // Drained concurrently, not afterwards. `push_delta` awaits on this
        // bounded channel, so a model that emits more than 32 deltas would
        // block forever against a receiver that only starts reading once the
        // call returns — and no timeout covers a channel send. The daemon's own
        // chat path already drains as it goes; only this test did not.
        let collector = tokio::spawn(async move {
            let mut tokens = Vec::new();
            while let Some(token) = rx.recv().await {
                tokens.push(token);
            }
            tokens
        });
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(90))
            .build()
            .unwrap();
        let text = generate_streaming(
            &client,
            &config,
            "Reply with exactly the two characters: OK",
            &[],
            Some("You reply with the requested characters and nothing else."),
            tx,
            Cancellation::default(),
        )
        .await
        .expect("ollama /api/chat stream");
        // `generate_streaming` owns the sender, so returning closes the channel
        // and the collector finishes on its own.
        let tokens = collector.await.expect("token collector panicked");
        eprintln!(
            "live ollama stream: {} token delta(s), assembled {:?}",
            tokens.len(),
            text.trim()
        );
        assert!(
            !tokens.is_empty(),
            "live Ollama should emit at least one token delta; assembled={text:?}"
        );
        assert!(!text.trim().is_empty(), "assembled text was empty");
    }

    async fn generate_against(
        provider: LlmProvider,
        origin: &str,
        cancellation: Cancellation,
    ) -> Result<(String, Vec<LlmDelta>), AdapterError> {
        let config = LlmRuntimeConfig {
            provider,
            base_url: origin.to_owned(),
            model: "mock".into(),
            api_key: None,
            context_tokens: None,
        };
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let (tx, mut rx) = mpsc::channel(16);
        let text = generate_streaming(&client, &config, "hi", &[], None, tx, cancellation).await?;
        let mut tokens = Vec::new();
        while let Ok(token) = rx.try_recv() {
            tokens.push(token);
        }
        Ok((text, tokens))
    }

    /// The declaration has to actually leave the process. Without `num_ctx` on
    /// the wire the server falls back to its own memory-derived default and
    /// cuts anything longer, which is precisely the case this exists to stop —
    /// and nothing downstream would report it.
    #[tokio::test]
    async fn the_window_we_budgeted_for_is_declared_on_the_wire() {
        let (origin, captured) = serve_capturing(
            concat!(r#"{"message":{"content":"ok"},"done":true}"#, "\n"),
            "application/x-ndjson",
        )
        .await;
        let config = LlmRuntimeConfig {
            provider: LlmProvider::Ollama,
            base_url: origin,
            model: "mock".into(),
            api_key: None,
            context_tokens: Some(32_768),
        };
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        let collector = tokio::spawn(async move { while rx.recv().await.is_some() {} });
        generate_streaming(
            &client,
            &config,
            "prompt",
            &[],
            None,
            tx,
            Cancellation::default(),
        )
        .await
        .unwrap();
        collector.await.unwrap();

        // Awaiting the capture is what makes this deterministic. Finishing the
        // response says nothing about the server task having recorded the
        // request; only the channel does.
        let request = captured.await.expect("the server never captured a request");
        let body = request
            .split_once("\r\n\r\n")
            .map(|(_, body)| body)
            .unwrap_or_default();
        // The whole request in the message, not just the body: a short read
        // shows up here as an empty string, and "EOF while parsing" says
        // nothing about where it came from.
        let parsed: Value = serde_json::from_str(body)
            .unwrap_or_else(|error| panic!("body was not JSON ({error}); request was:\n{request}"));
        assert_eq!(parsed["options"]["num_ctx"], 32_768, "{body}");
    }

    /// Like `serve_http`, but hands the request back over a channel.
    ///
    /// A shared cell would need the test to guess when the server task had
    /// filled it; a `oneshot` makes the wait explicit and the capture complete.
    async fn serve_capturing(
        body: &str,
        content_type: &str,
    ) -> (String, tokio::sync::oneshot::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let body = body.to_owned();
        let content_type = content_type.to_owned();
        let (captured_tx, captured_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let request = read_whole_request(&mut socket).await;
            let _ = captured_tx.send(request);
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            socket.write_all(header.as_bytes()).await.unwrap();
            socket.write_all(body.as_bytes()).await.unwrap();
        });
        (format!("http://{addr}"), captured_rx)
    }

    /// Reads the head, then exactly as many more bytes as it declares.
    ///
    /// One `read` is not one request: the client may flush headers and body
    /// separately, and TCP may split them anywhere. Stopping at the first chunk
    /// is how this test used to pass one run in five.
    async fn read_whole_request(socket: &mut tokio::net::TcpStream) -> String {
        let mut raw: Vec<u8> = Vec::new();
        let mut chunk = [0_u8; 1024];
        loop {
            let read = socket.read(&mut chunk).await.unwrap_or(0);
            if read == 0 {
                break;
            }
            raw.extend_from_slice(&chunk[..read]);
            let Some(head_end) = raw.windows(4).position(|window| window == b"\r\n\r\n") else {
                continue;
            };
            let head = String::from_utf8_lossy(&raw[..head_end]).to_lowercase();
            let declared = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length:"))
                .and_then(|value| value.trim().parse::<usize>().ok())
                .unwrap_or(0);
            if raw.len() >= head_end + 4 + declared {
                break;
            }
        }
        String::from_utf8_lossy(&raw).into_owned()
    }

    async fn serve_http(body: &str, content_type: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let body = body.to_owned();
        let content_type = content_type.to_owned();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0_u8; 4096];
            let _ = socket.read(&mut buf).await;
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            socket.write_all(header.as_bytes()).await.unwrap();
            for chunk in body.as_bytes().chunks(12) {
                socket.write_all(chunk).await.unwrap();
                let _ = socket.flush().await;
                tokio::time::sleep(Duration::from_millis(4)).await;
            }
        });
        format!("http://{addr}")
    }
}
