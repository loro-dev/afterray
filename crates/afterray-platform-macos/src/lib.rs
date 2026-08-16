//! macOS capture process adapter.
//!
//! Apple framework calls live in the tiny `AfterRayCaptureShim` Swift executable.
//! This crate owns its lifecycle and the bounded JSON-lines protocol. Capture
//! policy remains in Rust: callers explicitly request each screen artifact.

#![allow(unsafe_code)]

mod locale;
mod memory;
mod power;

pub use locale::preferred_languages;
pub use memory::{GIB, context_tokens_for_memory, local_context_tokens, total_memory_bytes};

pub use power::{
    apply_background_qos, battery_fraction, load_per_core, on_ac_power, seconds_since_user_input,
};

use afterray_core::{CaptureBackend, CoreError};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tokio::time::{Duration, timeout};

const EVENT_BUFFER_CAPACITY: usize = 128;
const STOP_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct CaptureConfig {
    pub shim_path: PathBuf,
    pub output_dir: PathBuf,
    pub audio_segment_seconds: u64,
    pub jpeg_quality: f64,
    pub record_audio: bool,
}

impl CaptureConfig {
    #[must_use]
    pub fn new(shim_path: impl Into<PathBuf>, output_dir: impl Into<PathBuf>) -> Self {
        Self {
            shim_path: shim_path.into(),
            output_dir: output_dir.into(),
            audio_segment_seconds: 300,
            jpeg_quality: 0.95,
            record_audio: true,
        }
    }

    fn validate(&self) -> Result<(), CaptureError> {
        if self.audio_segment_seconds == 0 {
            return Err(CaptureError::InvalidConfig(
                "audio_segment_seconds must be greater than zero".into(),
            ));
        }
        if !(0.0..=1.0).contains(&self.jpeg_quality) {
            return Err(CaptureError::InvalidConfig(
                "jpeg_quality must be between 0 and 1".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ShimCommand<'a> {
    CaptureScreen {
        request_id: &'a str,
    },
    /// Bundle identifiers whose audio the helper must not write to disk while
    /// they are frontmost. Screen exclusions stay in the daemon (only the
    /// accessibility snapshot carries a URL); audio has no such snapshot and
    /// cannot be sliced after the fact, so it has to be suppressed at capture.
    SetExcludedBundles {
        bundle_ids: &'a [String],
    },
    Stop,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum CaptureEvent {
    Ready {
        display_id: u32,
        width: usize,
        height: usize,
    },
    Artifact {
        kind: ArtifactKind,
        path: PathBuf,
        content_type: String,
        started_at_ms: i64,
        ended_at_ms: i64,
        byte_count: u64,
        #[serde(default)]
        request_id: Option<String>,
    },
    Warning {
        code: String,
        message: String,
    },
    Failed {
        code: String,
        message: String,
    },
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    Screen,
    SystemAudio,
    Microphone,
    Accessibility,
}

#[derive(Debug, thiserror::Error)]
pub enum CaptureError {
    #[error("invalid capture configuration: {0}")]
    InvalidConfig(String),
    #[error("capture shim is already running")]
    AlreadyRunning,
    #[error("capture shim is not running")]
    NotRunning,
    #[error("failed to start capture shim at {path}: {source}")]
    Spawn {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("capture shim I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("capture shim emitted invalid JSON: {line}: {source}")]
    InvalidEvent {
        line: String,
        source: serde_json::Error,
    },
    #[error("capture shim did not stop within ten seconds")]
    StopTimeout,
}

struct RunningShim {
    child: Child,
    stdin: ChildStdin,
    reader: JoinHandle<()>,
}

/// Rust-owned adapter for the native `ScreenCaptureKit` helper.
///
/// Only one consumer should call [`Self::next_event`]. The bounded channel is
/// intentional: if the daemon stops consuming artifacts, the helper stdout
/// pipe eventually applies backpressure instead of growing memory without
/// bound.
pub struct MacOsCaptureBackend {
    config: CaptureConfig,
    record_audio: AtomicBool,
    excluded_bundle_ids: std::sync::Mutex<Vec<String>>,
    running: Mutex<Option<RunningShim>>,
    events_tx: mpsc::Sender<Result<CaptureEvent, CaptureError>>,
    events_rx: Mutex<mpsc::Receiver<Result<CaptureEvent, CaptureError>>>,
}

impl MacOsCaptureBackend {
    #[must_use]
    pub fn new(config: CaptureConfig) -> Arc<Self> {
        let (events_tx, events_rx) = mpsc::channel(EVENT_BUFFER_CAPACITY);
        let record_audio = AtomicBool::new(config.record_audio);
        Arc::new(Self {
            config,
            record_audio,
            excluded_bundle_ids: std::sync::Mutex::new(Vec::new()),
            running: Mutex::new(None),
            events_tx,
            events_rx: Mutex::new(events_rx),
        })
    }

    pub fn set_record_audio(&self, enabled: bool) {
        self.record_audio.store(enabled, Ordering::Relaxed);
    }

    #[must_use]
    pub fn record_audio(&self) -> bool {
        self.record_audio.load(Ordering::Relaxed)
    }

    /// Replaces the audio exclusion list and pushes it to a running helper.
    ///
    /// The list is remembered so that [`Self::start_capture`] can hand it to
    /// the next helper before any sample buffer is written.
    ///
    /// # Errors
    ///
    /// Returns an error only when the helper is running but the command could
    /// not be written; a stopped helper is not an error.
    pub async fn set_excluded_bundle_ids(
        &self,
        bundle_ids: Vec<String>,
    ) -> Result<(), CaptureError> {
        {
            let mut excluded = self
                .excluded_bundle_ids
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if *excluded == bundle_ids {
                return Ok(());
            }
            *excluded = bundle_ids;
        }
        let mut running = self.running.lock().await;
        let Some(process) = running.as_mut() else {
            return Ok(());
        };
        self.write_excluded_bundles(&mut process.stdin).await
    }

    async fn write_excluded_bundles(&self, stdin: &mut ChildStdin) -> Result<(), CaptureError> {
        let bundle_ids = self
            .excluded_bundle_ids
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        write_command(
            stdin,
            &ShimCommand::SetExcludedBundles {
                bundle_ids: &bundle_ids,
            },
        )
        .await
    }

    /// Starts the native helper and its bounded event reader.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid configuration, an already running helper,
    /// output-directory creation failure, or process startup failure.
    pub async fn start_capture(&self) -> Result<(), CaptureError> {
        self.config.validate()?;
        let mut running = self.running.lock().await;
        if running.is_some() {
            return Err(CaptureError::AlreadyRunning);
        }
        tokio::fs::create_dir_all(&self.config.output_dir).await?;

        let mut command = Command::new(&self.config.shim_path);
        command
            .arg("--output-dir")
            .arg(&self.config.output_dir)
            .arg("--audio-segment-seconds")
            .arg(self.config.audio_segment_seconds.to_string())
            .arg("--jpeg-quality")
            .arg(self.config.jpeg_quality.to_string());
        if !self.record_audio() {
            command.arg("--no-audio");
        }
        eprintln!(
            "capture: spawning {} --output-dir {} audio={}",
            self.config.shim_path.display(),
            self.config.output_dir.display(),
            self.record_audio()
        );
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .map_err(|source| CaptureError::Spawn {
                path: self.config.shim_path.clone(),
                source,
            })?;
        eprintln!("capture: shim pid {:?}", child.id());
        let mut stdin = child.stdin.take().ok_or_else(|| {
            CaptureError::Io(std::io::Error::other("capture shim stdin was not piped"))
        })?;
        // Written before the helper has even finished starting ScreenCaptureKit:
        // the bytes wait in the pipe and are read on its first loop iteration,
        // so audio from an excluded app is suppressed from the first segment.
        self.write_excluded_bundles(&mut stdin).await?;
        let stdout = child.stdout.take().ok_or_else(|| {
            CaptureError::Io(std::io::Error::other("capture shim stdout was not piped"))
        })?;
        let events_tx = self.events_tx.clone();
        let reader = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        eprintln!("capture: shim stdout {line}");
                        let parsed =
                            serde_json::from_str::<CaptureEvent>(&line).map_err(|source| {
                                CaptureError::InvalidEvent {
                                    line: line.clone(),
                                    source,
                                }
                            });
                        if events_tx.send(parsed).await.is_err() {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(error) => {
                        let _ = events_tx.send(Err(CaptureError::Io(error))).await;
                        break;
                    }
                }
            }
        });
        *running = Some(RunningShim {
            child,
            stdin,
            reader,
        });
        Ok(())
    }

    /// Requests one JPEG from the most recent complete display frame.
    ///
    /// # Errors
    ///
    /// Returns an error when the identifier is invalid, the helper is not
    /// running, or the command cannot be written to the helper.
    pub async fn capture_screen(&self, request_id: &str) -> Result<(), CaptureError> {
        if request_id.is_empty() || request_id.contains(['\n', '\r']) {
            return Err(CaptureError::InvalidConfig(
                "request_id must be non-empty and single-line".into(),
            ));
        }
        let mut running = self.running.lock().await;
        let process = running.as_mut().ok_or(CaptureError::NotRunning)?;
        write_command(
            &mut process.stdin,
            &ShimCommand::CaptureScreen { request_id },
        )
        .await
    }

    pub async fn next_event(&self) -> Option<Result<CaptureEvent, CaptureError>> {
        self.events_rx.lock().await.recv().await
    }

    /// Stops capture, finalizes open audio segments, and waits for the helper.
    ///
    /// # Errors
    ///
    /// Returns an error when the helper is not running, communication fails,
    /// finalization exceeds the timeout, or the helper exits unsuccessfully.
    pub async fn stop_capture(&self) -> Result<(), CaptureError> {
        let mut running = self.running.lock().await;
        let Some(mut process) = running.take() else {
            return Err(CaptureError::NotRunning);
        };
        write_command(&mut process.stdin, &ShimCommand::Stop).await?;
        drop(process.stdin);
        let status = timeout(STOP_TIMEOUT, process.child.wait())
            .await
            .map_err(|_| CaptureError::StopTimeout)??;
        let Ok(reader_result) = timeout(STOP_TIMEOUT, &mut process.reader).await else {
            process.reader.abort();
            return Err(CaptureError::StopTimeout);
        };
        reader_result.map_err(|error| {
            CaptureError::Io(std::io::Error::other(format!(
                "capture event reader failed: {error}"
            )))
        })?;
        if !status.success() {
            return Err(CaptureError::Io(std::io::Error::other(format!(
                "capture shim exited with {status}"
            ))));
        }
        Ok(())
    }
}

async fn write_command(
    stdin: &mut ChildStdin,
    command: &ShimCommand<'_>,
) -> Result<(), CaptureError> {
    let mut bytes = serde_json::to_vec(command).expect("shim commands are always serializable");
    bytes.push(b'\n');
    stdin.write_all(&bytes).await?;
    stdin.flush().await?;
    Ok(())
}

#[async_trait]
impl CaptureBackend for MacOsCaptureBackend {
    async fn start(&self) -> Result<(), CoreError> {
        self.start_capture()
            .await
            .map_err(|error| CoreError::Capture(error.to_string()))
    }

    async fn stop(&self) -> Result<(), CoreError> {
        self.stop_capture()
            .await
            .map_err(|error| CoreError::Capture(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_artifact_event() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"artifact","kind":"screen","path":"/tmp/frame.jpg","content_type":"image/jpeg","started_at_ms":100,"ended_at_ms":100,"byte_count":42,"request_id":"moment-1"}"#,
        )
        .unwrap();
        assert_eq!(
            event,
            CaptureEvent::Artifact {
                kind: ArtifactKind::Screen,
                path: PathBuf::from("/tmp/frame.jpg"),
                content_type: "image/jpeg".into(),
                started_at_ms: 100,
                ended_at_ms: 100,
                byte_count: 42,
                request_id: Some("moment-1".into()),
            }
        );
    }

    #[test]
    fn rejects_invalid_config() {
        let mut config = CaptureConfig::new("shim", "/tmp/output");
        config.jpeg_quality = 1.5;
        assert!(matches!(
            config.validate(),
            Err(CaptureError::InvalidConfig(_))
        ));
    }

    #[test]
    fn command_is_one_json_line() {
        let bytes = serde_json::to_vec(&ShimCommand::CaptureScreen {
            request_id: "moment-1",
        })
        .unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            r#"{"command":"capture_screen","request_id":"moment-1"}"#
        );
    }

    /// The helper suppresses audio by bundle id, so the wire form has to stay
    /// a single line with the ids exactly as the daemon normalized them.
    #[test]
    fn the_exclusion_command_is_one_json_line() {
        let bundle_ids = vec![
            "com.bitwarden.desktop".to_owned(),
            "org.mozilla.firefox".to_owned(),
        ];
        let bytes = serde_json::to_vec(&ShimCommand::SetExcludedBundles {
            bundle_ids: &bundle_ids,
        })
        .unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            r#"{"command":"set_excluded_bundles","bundle_ids":["com.bitwarden.desktop","org.mozilla.firefox"]}"#
        );
    }

    /// An empty list still has to be sent: it is how the daemon tells a helper
    /// that the user just cleared the last exclusion.
    #[test]
    fn an_empty_exclusion_list_still_serializes() {
        let bundle_ids: Vec<String> = Vec::new();
        let bytes = serde_json::to_vec(&ShimCommand::SetExcludedBundles {
            bundle_ids: &bundle_ids,
        })
        .unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            r#"{"command":"set_excluded_bundles","bundle_ids":[]}"#
        );
    }

    #[test]
    fn config_accepts_path_types() {
        let config =
            CaptureConfig::new(std::path::Path::new("shim"), std::path::Path::new("output"));
        assert_eq!(config.shim_path, std::path::Path::new("shim"));
        assert_eq!(config.output_dir, std::path::Path::new("output"));
        assert!((config.jpeg_quality - 0.95).abs() < f64::EPSILON);
    }
}
