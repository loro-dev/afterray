use crate::{AdapterError, Cancellation, ModelAdapter, ModelCapability, ModelInput, ModelOutput};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf, process::Stdio, time::Duration};
use tokio::{io::AsyncWriteExt, process::Command};

pub const WORKER_PROTOCOL_VERSION: u32 = 1;

/// One-shot JSON request written to the worker's stdin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerRequest {
    pub protocol_version: u32,
    pub job_id: String,
    pub capability: ModelCapability,
    pub input: ModelInput,
}

/// One-shot JSON response read from the worker's stdout.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerResponse {
    pub protocol_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<ModelOutput>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub retryable: bool,
}

/// Configuration for any executable implementing the `AfterRay` worker contract.
#[derive(Debug, Clone)]
pub struct ProcessAdapterConfig {
    pub name: String,
    pub capability: ModelCapability,
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub working_directory: Option<PathBuf>,
    pub timeout: Duration,
    pub max_output_bytes: usize,
}

impl ProcessAdapterConfig {
    #[must_use]
    pub fn new(
        name: impl Into<String>,
        capability: ModelCapability,
        program: impl Into<PathBuf>,
    ) -> Self {
        Self {
            name: name.into(),
            capability,
            program: program.into(),
            args: Vec::new(),
            env: BTreeMap::new(),
            working_directory: None,
            timeout: Duration::from_secs(300),
            max_output_bytes: 16 * 1024 * 1024,
        }
    }
}

#[derive(Debug)]
pub struct ProcessAdapter {
    config: ProcessAdapterConfig,
}

impl ProcessAdapter {
    #[must_use]
    pub const fn new(config: ProcessAdapterConfig) -> Self {
        Self { config }
    }
}

#[async_trait]
impl ModelAdapter for ProcessAdapter {
    fn capability(&self) -> ModelCapability {
        self.config.capability
    }

    fn name(&self) -> &str {
        &self.config.name
    }

    async fn execute(
        &self,
        job_id: &str,
        input: &ModelInput,
        cancellation: Cancellation,
    ) -> Result<ModelOutput, AdapterError> {
        if input.capability() != self.config.capability {
            return Err(AdapterError::InvalidOutput(format!(
                "adapter `{}` handles {:?}, not {:?}",
                self.config.name,
                self.config.capability,
                input.capability()
            )));
        }

        validate_local_input(input).await?;
        let request = WorkerRequest {
            protocol_version: WORKER_PROTOCOL_VERSION,
            job_id: job_id.to_owned(),
            capability: self.config.capability,
            input: input.clone(),
        };
        let payload = serde_json::to_vec(&request)
            .map_err(|error| AdapterError::InvalidOutput(error.to_string()))?;

        let mut command = Command::new(&self.config.program);
        command
            .args(&self.config.args)
            .envs(&self.config.env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(directory) = &self.config.working_directory {
            command.current_dir(directory);
        }

        let mut child = command.spawn().map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                AdapterError::MissingExecutable {
                    program: self.config.program.display().to_string(),
                }
            } else {
                AdapterError::Io(error)
            }
        })?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| AdapterError::Process("worker stdin was not available".to_owned()))?;
        stdin.write_all(&payload).await?;
        stdin.write_all(b"\n").await?;
        drop(stdin);

        let wait = child.wait_with_output();
        tokio::pin!(wait);
        let timeout = tokio::time::sleep(self.config.timeout);
        tokio::pin!(timeout);

        let output = tokio::select! {
            () = cancellation.cancelled() => return Err(AdapterError::Cancelled),
            () = &mut timeout => return Err(AdapterError::Timeout {
                seconds: self.config.timeout.as_secs(),
            }),
            result = &mut wait => result?,
        };

        if !output.stderr.is_empty() {
            eprint!("{}", String::from_utf8_lossy(&output.stderr));
        }
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(AdapterError::Process(truncate(&stderr, 4_096)));
        }
        if output.stdout.len() > self.config.max_output_bytes {
            return Err(AdapterError::InvalidOutput(format!(
                "worker output was {} bytes, exceeding the {} byte limit",
                output.stdout.len(),
                self.config.max_output_bytes
            )));
        }

        let response: WorkerResponse = serde_json::from_slice(&output.stdout).map_err(|error| {
            AdapterError::InvalidOutput(format!(
                "{error}; stdout was: {}",
                truncate(&String::from_utf8_lossy(&output.stdout), 4_096)
            ))
        })?;
        if response.protocol_version != WORKER_PROTOCOL_VERSION {
            return Err(AdapterError::InvalidOutput(format!(
                "worker protocol version {} is unsupported",
                response.protocol_version
            )));
        }
        if let Some(error) = response.error {
            return if response.retryable {
                Err(AdapterError::Process(error))
            } else {
                Err(AdapterError::MissingModel(error))
            };
        }
        let model_output = response.output.ok_or_else(|| {
            AdapterError::InvalidOutput("worker returned neither output nor error".to_owned())
        })?;
        if model_output.capability() != self.config.capability {
            return Err(AdapterError::InvalidOutput(format!(
                "worker returned {:?} output for {:?} request",
                model_output.capability(),
                self.config.capability
            )));
        }
        Ok(model_output)
    }
}

async fn validate_local_input(input: &ModelInput) -> Result<(), AdapterError> {
    let path = match input {
        ModelInput::Ocr { image_path, .. } => Some(image_path),
        ModelInput::Asr { audio_path, .. } => Some(audio_path),
        ModelInput::Embedding { .. } | ModelInput::Llm { .. } => None,
    };
    if let Some(path) = path {
        match tokio::fs::metadata(path).await {
            Ok(metadata) if metadata.is_file() => {}
            Ok(_) => {
                return Err(AdapterError::MissingModel(format!(
                    "input `{}` is not a file",
                    path.display()
                )));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(AdapterError::MissingModel(format!(
                    "input file `{}` does not exist",
                    path.display()
                )));
            }
            Err(error) => return Err(AdapterError::Io(error)),
        }
    }
    Ok(())
}

fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[tokio::test]
    async fn executes_a_real_json_worker_process() {
        let script = r#"
import json, sys
request = json.load(sys.stdin)
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "embedding", "vector": [1.0, 2.0, 3.0]},
  "retryable": False
}))
"#;
        let mut config = ProcessAdapterConfig::new(
            "test-worker",
            ModelCapability::Embedding,
            "/usr/bin/python3",
        );
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let adapter = ProcessAdapter::new(config);
        let output = adapter
            .execute(
                "job-1",
                &ModelInput::Embedding {
                    text: "hello".to_owned(),
                },
                Cancellation::default(),
            )
            .await
            .unwrap();
        assert_eq!(
            output,
            ModelOutput::Embedding {
                vector: vec![1.0, 2.0, 3.0]
            }
        );
    }

    #[tokio::test]
    async fn missing_executable_has_an_actionable_error() {
        let config =
            ProcessAdapterConfig::new("missing", ModelCapability::Llm, "/afterray/does-not-exist");
        let adapter = ProcessAdapter::new(config);
        let error = adapter
            .execute(
                "job-1",
                &ModelInput::Llm {
                    messages: Vec::new(),
                    prompt: "hello".to_owned(),
                    system: None,
                },
                Cancellation::default(),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, AdapterError::MissingExecutable { .. }));
        assert!(error.to_string().contains("configure the adapter path"));
    }

    #[tokio::test]
    async fn cancellation_stops_a_real_worker_process() {
        let script = "import sys, time; sys.stdin.read(); time.sleep(30)";
        let mut config = ProcessAdapterConfig::new(
            "slow-worker",
            ModelCapability::Embedding,
            "/usr/bin/python3",
        );
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let adapter = Arc::new(ProcessAdapter::new(config));
        let cancellation = Cancellation::default();
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            adapter
                .execute(
                    "job-1",
                    &ModelInput::Embedding {
                        text: "hello".to_owned(),
                    },
                    task_cancellation,
                )
                .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        cancellation.cancel();
        let error = task.await.unwrap().unwrap_err();
        assert!(matches!(error, AdapterError::Cancelled));
    }
}
