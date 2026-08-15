use crate::{AdapterError, Cancellation, ManifestFile, ModelInput, ModelOutput, READY_MARKER};
use afterray_protocol::ModelPackState;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::{Mutex as AsyncMutex, mpsc},
};

pub const MLX_WORKER_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone)]
pub struct PersistentMlxConfig {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub model_dir: PathBuf,
    pub revision: String,
    pub manifest: Vec<ManifestFile>,
    pub load_timeout: Duration,
    pub generate_timeout: Duration,
    pub restart_backoff: Duration,
    /// Enabled by default. Set to false only for a targeted recovery path.
    pub enable_kv_cache: bool,
}

impl PersistentMlxConfig {
    #[must_use]
    pub fn new(program: impl Into<PathBuf>, model_dir: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            model_dir: model_dir.into(),
            revision: String::new(),
            manifest: Vec::new(),
            load_timeout: Duration::from_secs(180),
            generate_timeout: Duration::from_secs(300),
            restart_backoff: Duration::from_secs(1),
            enable_kv_cache: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MlxWorkerHealth {
    pub state: ModelPackState,
    pub pid: Option<u32>,
    pub runtime: Option<String>,
    pub error: Option<String>,
}

impl Default for MlxWorkerHealth {
    fn default() -> Self {
        Self {
            state: ModelPackState::NotDownloaded,
            pid: None,
            runtime: None,
            error: None,
        }
    }
}

pub struct PersistentMlxAdapter {
    config: PersistentMlxConfig,
    inner: AsyncMutex<Runtime>,
    health: Arc<Mutex<MlxWorkerHealth>>,
}

struct Runtime {
    worker: Option<WorkerProcess>,
    generation: u64,
    next_spawn: Option<Instant>,
}

struct WorkerProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl PersistentMlxAdapter {
    #[must_use]
    pub fn new(config: PersistentMlxConfig) -> Self {
        Self {
            config,
            inner: AsyncMutex::new(Runtime {
                worker: None,
                generation: 0,
                next_spawn: None,
            }),
            health: Arc::new(Mutex::new(MlxWorkerHealth::default())),
        }
    }

    #[must_use]
    pub fn health(&self) -> MlxWorkerHealth {
        self.health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub async fn shutdown(&self) {
        let mut runtime = self.inner.lock().await;
        if let Some(mut worker) = runtime.worker.take() {
            let _ = worker.child.kill().await;
            let _ = worker.child.wait().await;
        }
        runtime.next_spawn = None;
        self.set_health(ModelPackState::NotDownloaded, None, None, None);
    }

    pub async fn execute_streaming(
        &self,
        job_id: &str,
        input: &ModelInput,
        token_tx: Option<mpsc::Sender<String>>,
        cancellation: Cancellation,
    ) -> Result<ModelOutput, AdapterError> {
        if let Some(error) = mlx_platform_incompatibility() {
            self.set_health(ModelPackState::Incompatible, None, None, Some(error.into()));
            return Err(AdapterError::Process(error.into()));
        }
        let ModelInput::Llm { prompt, system } = input else {
            return Err(AdapterError::InvalidOutput(
                "MLX adapter received a non-LLM input".into(),
            ));
        };
        let mut runtime = self.inner.lock().await;
        self.ensure_started(&mut runtime).await?;
        let messages: Vec<MlxMessage<'_>> = system
            .iter()
            .filter(|value| !value.trim().is_empty())
            .map(|content| MlxMessage {
                role: "system",
                content,
            })
            .chain(std::iter::once(MlxMessage {
                role: "user",
                content: prompt,
            }))
            .collect();
        let request = MlxRequest::Generate {
            v: MLX_WORKER_PROTOCOL_VERSION,
            request_id: job_id,
            messages: messages.clone(),
            images: Vec::new(),
            max_tokens: 512,
            use_kv_cache: self.config.enable_kv_cache,
        };
        let first = self
            .run_generate(
                &mut runtime,
                request,
                job_id,
                token_tx,
                cancellation.clone(),
            )
            .await;
        // If reuse itself fails before the user has received a token, retry the
        // same request with a fresh session in the already-loaded container.
        // This preserves the persistent worker and avoids duplicate deltas.
        let result = match first.result {
            Err(error)
                if self.config.enable_kv_cache
                    && !first.emitted_delta
                    && !matches!(error, AdapterError::Cancelled) =>
            {
                let fallback = MlxRequest::Generate {
                    v: MLX_WORKER_PROTOCOL_VERSION,
                    request_id: job_id,
                    messages,
                    images: Vec::new(),
                    max_tokens: 512,
                    use_kv_cache: false,
                };
                self.run_generate(&mut runtime, fallback, job_id, None, cancellation)
                    .await
                    .result
            }
            result => result,
        };
        if let Err(error) = &result
            && error.retryable()
        {
            self.fail_worker(&mut runtime, error.to_string()).await;
        }
        result.map(|text| ModelOutput::Llm { text })
    }

    async fn ensure_started(&self, runtime: &mut Runtime) -> Result<(), AdapterError> {
        if let Some(worker) = runtime.worker.as_mut() {
            match worker.child.try_wait() {
                Ok(None) => return Ok(()),
                Ok(Some(status)) => {
                    runtime.worker = None;
                    self.set_health(
                        ModelPackState::Failed,
                        None,
                        None,
                        Some(format!("MLX worker exited with {status}")),
                    );
                }
                Err(error) => {
                    runtime.worker = None;
                    return Err(AdapterError::Io(error));
                }
            }
        }
        if let Some(next_spawn) = runtime.next_spawn
            && Instant::now() < next_spawn
        {
            return Err(AdapterError::Process(
                "MLX worker restart is waiting for backoff".into(),
            ));
        }
        self.verify_model().await?;
        let mut command = Command::new(&self.config.program);
        command
            .args(&self.config.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AdapterError::MissingExecutable {
                    program: self.config.program.display().to_string(),
                }
            } else {
                AdapterError::Io(error)
            }
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::Process("MLX worker stdin was not piped".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AdapterError::Process("MLX worker stdout was not piped".into()))?;
        runtime.generation = runtime.generation.saturating_add(1);
        let request_id = format!("startup-{}", runtime.generation);
        let mut worker = WorkerProcess {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        };
        write_request(
            &mut worker.stdin,
            &MlxRequest::Load {
                v: MLX_WORKER_PROTOCOL_VERSION,
                request_id: &request_id,
                model_dir: &self.config.model_dir.display().to_string(),
            },
        )
        .await?;
        let response = tokio::time::timeout(self.config.load_timeout, read_response(&mut worker))
            .await
            .map_err(|_| AdapterError::Timeout {
                seconds: self.config.load_timeout.as_secs(),
            })??;
        validate_response(&response, &request_id)?;
        if response.kind != "ready" {
            return Err(response_error(&response, "MLX worker did not become ready"));
        }
        let pid = worker.child.id();
        self.set_health(ModelPackState::Ready, pid, response.runtime.clone(), None);
        runtime.next_spawn = None;
        runtime.worker = Some(worker);
        Ok(())
    }

    async fn verify_model(&self) -> Result<(), AdapterError> {
        if self.config.manifest.is_empty() {
            return Ok(());
        }
        let marker = tokio::fs::read_to_string(self.config.model_dir.join(READY_MARKER))
            .await
            .map_err(|error| {
                AdapterError::MissingModel(format!(
                    "{} is not ready: {error}",
                    self.config.model_dir.display()
                ))
            })?;
        let marker: Value = serde_json::from_str(&marker).map_err(|error| {
            AdapterError::MissingModel(format!("ready marker is invalid: {error}"))
        })?;
        if marker.get("revision").and_then(Value::as_str) != Some(self.config.revision.as_str()) {
            return Err(AdapterError::MissingModel(format!(
                "model revision does not match {}",
                self.config.revision
            )));
        }
        self.set_health(ModelPackState::Verifying, None, None, None);
        let path = self.config.model_dir.clone();
        let files = self.config.manifest.clone();
        tokio::task::spawn_blocking(move || crate::verify_files(&path, &files))
            .await
            .map_err(|error| {
                AdapterError::Process(format!("model verification task failed: {error}"))
            })?
            .map_err(|error| AdapterError::MissingModel(error.to_string()))
    }

    async fn run_generate(
        &self,
        runtime: &mut Runtime,
        request: MlxRequest<'_>,
        request_id: &str,
        token_tx: Option<mpsc::Sender<String>>,
        cancellation: Cancellation,
    ) -> GenerateAttempt {
        let Some(worker) = runtime.worker.as_mut() else {
            return GenerateAttempt::failed(AdapterError::Process(
                "MLX worker disappeared before generation".into(),
            ));
        };
        if let Err(error) = write_request(&mut worker.stdin, &request).await {
            return GenerateAttempt::failed(error);
        }
        self.set_health(
            ModelPackState::InUse,
            worker.child.id(),
            self.health().runtime,
            None,
        );
        let mut emitted_delta = false;
        let generation = async {
            loop {
                tokio::select! {
                    () = cancellation.cancelled() => {
                        write_request(&mut worker.stdin, &MlxRequest::Cancel {
                            v: MLX_WORKER_PROTOCOL_VERSION,
                            request_id,
                        }).await?;
                        let response = read_response(worker).await?;
                        validate_response(&response, request_id)?;
                        if response.kind != "cancelled" {
                            return Err(response_error(&response, "MLX worker did not acknowledge cancellation"));
                        }
                        return Err(AdapterError::Cancelled);
                    }
                    response = read_response(worker) => {
                        let response = response?;
                        validate_response(&response, request_id)?;
                        match response.kind.as_str() {
                            "delta" => {
                                if let Some(text) = response.text.filter(|text| !text.is_empty())
                                    && let Some(tx) = &token_tx
                                {
                                    emitted_delta = true;
                                    let _ = tx.send(text).await;
                                }
                            }
                            "final" => {
                                let final_text = normalize_model_output(response.text.as_deref().unwrap_or(""));
                                if final_text.is_empty() {
                                    return Err(AdapterError::InvalidOutput("MLX worker returned empty text".into()));
                                }
                                return Ok(final_text);
                            }
                            "error" => return Err(response_error(&response, "MLX generation failed")),
                            other => return Err(AdapterError::InvalidOutput(format!(
                                "unexpected MLX worker response kind `{other}`"
                            ))),
                        }
                    }
                }
            }
        };
        let result = match tokio::time::timeout(self.config.generate_timeout, generation).await {
            Ok(result) => result,
            Err(_) => Err(AdapterError::Timeout {
                seconds: self.config.generate_timeout.as_secs(),
            }),
        };
        if result.is_ok() {
            let pid = worker.child.id();
            self.set_health(ModelPackState::Ready, pid, self.health().runtime, None);
        }
        GenerateAttempt {
            result,
            emitted_delta,
        }
    }

    async fn fail_worker(&self, runtime: &mut Runtime, error: String) {
        if let Some(mut worker) = runtime.worker.take() {
            let _ = worker.child.kill().await;
            let _ = worker.child.wait().await;
        }
        runtime.next_spawn = Some(Instant::now() + self.config.restart_backoff);
        self.set_health(ModelPackState::Failed, None, None, Some(error));
    }

    fn set_health(
        &self,
        state: ModelPackState,
        pid: Option<u32>,
        runtime: Option<String>,
        error: Option<String>,
    ) {
        *self
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = MlxWorkerHealth {
            state,
            pid,
            runtime,
            error,
        };
    }
}

fn mlx_platform_incompatibility() -> Option<&'static str> {
    if !cfg!(target_os = "macos") {
        return Some("MLX local inference requires macOS 14 or later on Apple Silicon");
    }
    if !cfg!(target_arch = "aarch64") {
        return Some("MLX local inference requires Apple Silicon");
    }
    None
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum MlxRequest<'a> {
    Load {
        v: u32,
        request_id: &'a str,
        model_dir: &'a str,
    },
    Generate {
        v: u32,
        request_id: &'a str,
        messages: Vec<MlxMessage<'a>>,
        images: Vec<&'a str>,
        max_tokens: u32,
        use_kv_cache: bool,
    },
    Cancel {
        v: u32,
        request_id: &'a str,
    },
}

#[derive(Serialize, Clone)]
struct MlxMessage<'a> {
    role: &'a str,
    content: &'a str,
}

struct GenerateAttempt {
    result: Result<String, AdapterError>,
    emitted_delta: bool,
}

impl GenerateAttempt {
    fn failed(error: AdapterError) -> Self {
        Self {
            result: Err(error),
            emitted_delta: false,
        }
    }
}

#[derive(Debug, Deserialize)]
struct MlxResponse {
    v: u32,
    kind: String,
    request_id: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    runtime: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

async fn write_request(
    stdin: &mut ChildStdin,
    request: &MlxRequest<'_>,
) -> Result<(), AdapterError> {
    let mut encoded = serde_json::to_vec(request).map_err(|error| {
        AdapterError::InvalidOutput(format!("could not encode MLX request: {error}"))
    })?;
    encoded.push(b'\n');
    stdin.write_all(&encoded).await?;
    stdin.flush().await?;
    Ok(())
}

async fn read_response(worker: &mut WorkerProcess) -> Result<MlxResponse, AdapterError> {
    let mut line = String::new();
    let read = worker.stdout.read_line(&mut line).await?;
    if read == 0 {
        let status = worker.child.try_wait().ok().flatten();
        return Err(AdapterError::Process(format!(
            "MLX worker closed stdout{}",
            status.map_or_else(String::new, |status| format!(" ({status})"))
        )));
    }
    serde_json::from_str(line.trim_end()).map_err(|error| {
        AdapterError::InvalidOutput(format!(
            "MLX worker wrote non-protocol stdout: {error}; line={}",
            truncate(&line, 200)
        ))
    })
}

fn validate_response(response: &MlxResponse, request_id: &str) -> Result<(), AdapterError> {
    if response.v != MLX_WORKER_PROTOCOL_VERSION {
        return Err(AdapterError::InvalidOutput(format!(
            "MLX worker protocol {} is unsupported",
            response.v
        )));
    }
    if response.request_id != request_id {
        return Err(AdapterError::InvalidOutput(format!(
            "MLX worker response id `{}` did not match `{request_id}`",
            response.request_id
        )));
    }
    Ok(())
}

fn response_error(response: &MlxResponse, fallback: &str) -> AdapterError {
    AdapterError::Process(response.error.clone().unwrap_or_else(|| fallback.into()))
}

#[must_use]
pub fn normalize_model_output(text: &str) -> String {
    let mut visible = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        if let Some(start) = rest.find("<think>") {
            visible.push_str(&rest[..start]);
            let after = &rest[start + "<think>".len()..];
            if let Some(end) = after.find("</think>") {
                rest = &after[end + "</think>".len()..];
                continue;
            }
            break;
        }
        visible.push_str(rest);
        break;
    }
    for token in [
        "<|im_start|>",
        "<|im_end|>",
        "<|endoftext|>",
        "<|vision_start|>",
        "<|vision_end|>",
        "<|image_pad|>",
        "<|video_pad|>",
    ] {
        visible = visible.replace(token, "");
    }
    visible.trim().to_owned()
}

fn truncate(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    const LOOP_WORKER: &str = r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"kind":"load"'*)
      printf '{"v":1,"kind":"ready","request_id":"%s","runtime":"fake@pid-%s"}\n' "$id" "$$"
      ;;
    *'"kind":"generate"'*)
      printf '{"v":1,"kind":"delta","request_id":"%s","text":"hello "}\n' "$id"
      printf '{"v":1,"kind":"final","request_id":"%s","text":"pid=%s"}\n' "$id" "$$"
      ;;
    *'"kind":"cancel"'*)
      printf '{"v":1,"kind":"cancelled","request_id":"%s"}\n' "$id"
      ;;
  esac
done
"#;

    fn test_adapter(script: &str) -> PersistentMlxAdapter {
        let mut config = PersistentMlxConfig::new("/bin/sh", "/tmp/fake-model");
        config.args = vec!["-c".into(), script.into()];
        config.load_timeout = Duration::from_secs(2);
        config.generate_timeout = Duration::from_secs(2);
        config.restart_backoff = Duration::from_millis(10);
        PersistentMlxAdapter::new(config)
    }

    fn prompt(value: &str) -> ModelInput {
        ModelInput::Llm {
            prompt: value.into(),
            system: Some("system".into()),
        }
    }

    #[test]
    fn output_normalization_drops_thinking_and_control_tokens() {
        assert_eq!(
            normalize_model_output("<think>private chain</think>\nFINAL safe<|im_end|>"),
            "FINAL safe"
        );
        assert_eq!(normalize_model_output("<think>unfinished"), "");
    }

    #[test]
    fn kv_cache_is_enabled_by_default() {
        assert!(PersistentMlxConfig::new("worker", "/model").enable_kv_cache);
    }

    #[tokio::test]
    async fn cache_error_retries_full_prefill_without_reloading_worker() {
        let script = r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"kind":"load"'*) printf '{"v":1,"kind":"ready","request_id":"%s","runtime":"fake"}\n' "$id" ;;
    *'"kind":"generate"'*'"use_kv_cache":true'*) printf '{"v":1,"kind":"error","request_id":"%s","error":"cache prefill failed"}\n' "$id" ;;
    *'"kind":"generate"'*) printf '{"v":1,"kind":"final","request_id":"%s","text":"fresh prefill"}\n' "$id" ;;
  esac
done
"#;
        let adapter = test_adapter(script);
        let output = adapter
            .execute_streaming("fallback", &prompt("one"), None, Cancellation::default())
            .await
            .unwrap();
        assert_eq!(
            output,
            ModelOutput::Llm {
                text: "fresh prefill".into()
            }
        );
        assert!(matches!(adapter.health().state, ModelPackState::Ready));
        adapter.shutdown().await;
    }

    #[tokio::test]
    async fn streams_and_reuses_one_worker_pid() {
        let adapter = test_adapter(LOOP_WORKER);
        let (tx, mut rx) = mpsc::channel(4);
        let first = adapter
            .execute_streaming("job-1", &prompt("one"), Some(tx), Cancellation::default())
            .await
            .unwrap();
        assert_eq!(rx.recv().await.as_deref(), Some("hello "));
        let second = adapter
            .execute_streaming("job-2", &prompt("two"), None, Cancellation::default())
            .await
            .unwrap();
        assert_eq!(first, second);
        assert!(matches!(adapter.health().state, ModelPackState::Ready));
        adapter.shutdown().await;
    }

    #[tokio::test]
    async fn cancellation_is_acknowledged_and_next_request_works() {
        let script = r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"kind":"load"'*) printf '{"v":1,"kind":"ready","request_id":"%s","runtime":"fake"}\n' "$id" ;;
    *'"kind":"cancel"'*) printf '{"v":1,"kind":"cancelled","request_id":"%s"}\n' "$id" ;;
    *'"request_id":"cancel-me"'*) ;;
    *'"kind":"generate"'*) printf '{"v":1,"kind":"final","request_id":"%s","text":"ok"}\n' "$id" ;;
  esac
done
"#;
        let adapter = Arc::new(test_adapter(script));
        let cancellation = Cancellation::default();
        let task_adapter = Arc::clone(&adapter);
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            task_adapter
                .execute_streaming("cancel-me", &prompt("wait"), None, task_cancellation)
                .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        cancellation.cancel();
        assert!(matches!(task.await.unwrap(), Err(AdapterError::Cancelled)));
        let next = adapter
            .execute_streaming(
                "after-cancel",
                &prompt("next"),
                None,
                Cancellation::default(),
            )
            .await
            .unwrap();
        assert_eq!(next, ModelOutput::Llm { text: "ok".into() });
        adapter.shutdown().await;
    }

    #[tokio::test]
    async fn crash_restarts_after_backoff() {
        let marker =
            std::env::temp_dir().join(format!("afterray-mlx-crash-{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let script = format!(
            r#"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"kind":"load"'*) printf '{{"v":1,"kind":"ready","request_id":"%s","runtime":"fake"}}\n' "$id" ;;
    *'"kind":"generate"'*)
      if [ ! -f '{marker}' ]; then /usr/bin/touch '{marker}'; exit 17; fi
      printf '{{"v":1,"kind":"final","request_id":"%s","text":"recovered"}}\n' "$id"
      ;;
  esac
done
"#,
            marker = marker.display()
        );
        let adapter = test_adapter(&script);
        assert!(
            adapter
                .execute_streaming("crash", &prompt("one"), None, Cancellation::default())
                .await
                .is_err()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
        let output = adapter
            .execute_streaming("retry", &prompt("two"), None, Cancellation::default())
            .await
            .unwrap();
        assert_eq!(
            output,
            ModelOutput::Llm {
                text: "recovered".into()
            }
        );
        adapter.shutdown().await;
        let _ = std::fs::remove_file(marker);
    }

    #[tokio::test]
    async fn rejects_non_json_stdout() {
        let adapter = test_adapter("printf 'startup banner\\n'; sleep 1");
        let error = adapter
            .execute_streaming("job", &prompt("one"), None, Cancellation::default())
            .await
            .unwrap_err();
        assert!(matches!(error, AdapterError::InvalidOutput(_)));
    }
}
