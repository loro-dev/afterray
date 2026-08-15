//! Remote token streaming used only by the chat path.
//!
//! `ModelQueue` still waits for a complete `ModelOutput`. These helpers
//! optionally copy token deltas onto a side channel while that full text
//! is assembled, so a client can render incrementally without a second
//! generation.

use super::{LlmRuntimeConfig, chat_completions_url, normalize_origin, remote_http_error};
use crate::{AdapterError, Cancellation};
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
    system: Option<&str>,
    token_tx: mpsc::Sender<String>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    match config.provider {
        afterray_protocol::LlmProvider::Ollama => {
            generate_ollama_stream(client, config, prompt, system, token_tx, cancellation).await
        }
        afterray_protocol::LlmProvider::OpenaiCompatible => {
            generate_openai_stream(client, config, prompt, system, token_tx, cancellation).await
        }
        afterray_protocol::LlmProvider::MlxLocal => Err(AdapterError::InvalidOutput(
            "MLX local generation uses the persistent worker protocol".into(),
        )),
    }
}

async fn generate_ollama_stream(
    client: &reqwest::Client,
    config: &LlmRuntimeConfig,
    prompt: &str,
    system: Option<&str>,
    token_tx: mpsc::Sender<String>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    let model = require_model(config)?;
    let origin = require_origin(config)?;
    let url = ollama_chat_url(&origin);
    let body = json!({
        "model": model,
        "messages": chat_messages(prompt, system),
        "stream": true,
    });
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
    prompt: &str,
    system: Option<&str>,
    token_tx: mpsc::Sender<String>,
    cancellation: Cancellation,
) -> Result<String, AdapterError> {
    let model = require_model(config)?;
    let origin = require_origin(config)?;
    let url = chat_completions_url(&origin);
    let body = json!({
        "model": model,
        "messages": chat_messages(prompt, system),
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

fn chat_messages(prompt: &str, system: Option<&str>) -> Vec<Value> {
    let mut messages = Vec::new();
    if let Some(system) = system.filter(|value| !value.is_empty()) {
        messages.push(json!({"role": "system", "content": system}));
    }
    messages.push(json!({"role": "user", "content": prompt}));
    messages
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
    token_tx: &mpsc::Sender<String>,
    parse_line: fn(&str) -> Option<String>,
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
    token_tx: &mpsc::Sender<String>,
    parse_line: fn(&str) -> Option<String>,
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

async fn push_delta(
    assembled: &mut String,
    token_tx: &mpsc::Sender<String>,
    delta: Option<String>,
) {
    let Some(delta) = delta.filter(|text| !text.is_empty()) else {
        return;
    };
    assembled.push_str(&delta);
    let _ = token_tx.send(delta).await;
}

/// `message.content` from one Ollama `/api/chat` JSON line.
#[must_use]
pub fn ollama_chat_delta(line: &str) -> Option<String> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    json_text(value.pointer("/message/content"))
}

/// `choices[0].delta.content` from one SSE `data:` line.
#[must_use]
pub fn openai_sse_delta(line: &str) -> Option<String> {
    let line = line.trim();
    let payload = line.strip_prefix("data:")?.trim();
    if payload.is_empty() || payload == "[DONE]" {
        return None;
    }
    let value: Value = serde_json::from_str(payload).ok()?;
    json_text(value.pointer("/choices/0/delta/content"))
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
    fn ollama_line_takes_message_content_only() {
        assert_eq!(
            ollama_chat_delta(
                r#"{"message":{"role":"assistant","content":"你","thinking":"hmm"},"done":false}"#
            )
            .as_deref(),
            Some("你")
        );
        assert!(
            ollama_chat_delta(r#"{"message":{"role":"assistant","content":""},"done":true}"#)
                .is_none()
        );
        assert!(ollama_chat_delta("not-json").is_none());
    }

    #[test]
    fn openai_sse_takes_delta_content() {
        assert_eq!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"content":"今"}}]}"#).as_deref(),
            Some("今")
        );
        assert!(
            openai_sse_delta(r#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#).is_none()
        );
        assert!(openai_sse_delta("data: [DONE]").is_none());
        assert!(openai_sse_delta("event: message").is_none());
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
        assert_eq!(tokens, ["你", "好"]);
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
        assert_eq!(tokens, ["hel", "lo"]);
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

    #[tokio::test]
    async fn live_ollama_streams_tokens_when_running() {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(8))
            .build()
            .unwrap();
        let ok = client
            .get("http://127.0.0.1:11434/api/tags")
            .send()
            .await
            .map(|response| response.status().is_success())
            .unwrap_or(false);
        if !ok {
            return;
        }
        let config = LlmRuntimeConfig {
            provider: LlmProvider::Ollama,
            base_url: String::new(),
            model: "qwen3.6:latest".into(),
            api_key: None,
        };
        let (tx, mut rx) = mpsc::channel(32);
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(90))
            .build()
            .unwrap();
        let text = generate_streaming(
            &client,
            &config,
            "Reply with exactly the two characters: OK",
            Some("You reply with the requested characters and nothing else."),
            tx,
            Cancellation::default(),
        )
        .await
        .expect("ollama /api/chat stream");
        let mut tokens = Vec::new();
        while let Ok(token) = rx.try_recv() {
            tokens.push(token);
        }
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
    ) -> Result<(String, Vec<String>), AdapterError> {
        let config = LlmRuntimeConfig {
            provider,
            base_url: origin.to_owned(),
            model: "mock".into(),
            api_key: None,
        };
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let (tx, mut rx) = mpsc::channel(16);
        let text = generate_streaming(&client, &config, "hi", None, tx, cancellation).await?;
        let mut tokens = Vec::new();
        while let Ok(token) = rx.try_recv() {
            tokens.push(token);
        }
        Ok((text, tokens))
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
