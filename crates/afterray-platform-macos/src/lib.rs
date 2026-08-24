//! macOS capture process adapter.
//!
//! Apple framework calls live in the tiny `AfterRayCaptureShim` Swift executable.
//! This crate owns its lifecycle and the bounded JSON-lines protocol. Capture
//! policy remains in Rust: callers explicitly request each screen artifact.

#![allow(unsafe_code)]

mod locale;
mod memory;
mod peer;
mod power;
mod process;
mod sysctl;

pub use locale::preferred_languages;
pub use memory::{GIB, context_tokens_for_memory, local_context_tokens, total_memory_bytes};
pub use peer::{
    APP_BUNDLE_IDENTIFIER, CodeIdentity, app_peer_is_trusted, parent_app_anchor,
    peer_is_afterray_app,
};

pub use power::{
    apply_background_qos, battery_fraction, load_per_core, on_ac_power, seconds_since_user_input,
};
pub use process::{ProcessUsage, process_usage, thermal_pressure};

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
// `stopCapture()` and the shim's synchronous audio finalization can take more
// than a scheduler tick on a healthy machine. Keep this below the daemon's
// aggregate capture drain budget, but long enough to preserve the last event.
const STOP_GRACE_TIMEOUT: Duration = Duration::from_millis(1_500);
const FORCE_REAP_TIMEOUT: Duration = Duration::from_millis(750);
// Only a helper already known to have failed or been forced down gets a local
// reader bound. A successful child exit leaves a finite stdout stream whose
// delivery may be backpressured by required vault imports.
const READER_DRAIN_TIMEOUT: Duration = Duration::from_millis(500);

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
    /// Coalesced user-input observations from the shim's listen-only event
    /// tap (docs/input-events-and-t1-acts-plan.md). Plain keystrokes arrive
    /// only as burst counts; pointer events arrive as resolved element
    /// identities, never coordinates. `dropped` counts records the shim's
    /// producer-side cap discarded.
    InputEvents {
        #[serde(default)]
        events: Vec<InputEventRecord>,
        #[serde(default)]
        dropped: u64,
    },
    Stopped,
}

/// One coalesced input observation. `kind` is `burst` (typing, with
/// `count`/`end_ms`/`ended_with`, and since event-capture v2 the typed `text`),
/// `command` (⌘-combo or Return/Tab/Esc, named in `command`; `return` and
/// `cmd-return` are the plan's *submit*, whose target carries the field's
/// `value`), `click`, `scroll` (coalesced, with `count`), `drag` (both ends in
/// `source`/`destination`), or `window_changed` (`application_name` /
/// `window_title`).
///
/// `kind` stays a plain string on purpose: the vault keeps it uninterpreted and
/// a newer shim's vocabulary must round-trip through an older daemon. Every
/// field added by event-capture v2 is optional with a serde default, so a batch
/// from the previous shim parses unchanged.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct InputEventRecord {
    pub at_ms: i64,
    pub kind: String,
    #[serde(default)]
    pub end_ms: Option<i64>,
    #[serde(default)]
    pub count: Option<u32>,
    #[serde(default)]
    pub ended_with: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub bundle_identifier: Option<String>,
    #[serde(default)]
    pub target: Option<InputTargetRef>,
    /// The characters of a typing run, pause-coalesced by the shim. Absent
    /// whenever the shim's secure guard fired — a guarded run keeps its count
    /// and nothing else.
    #[serde(default)]
    pub text: Option<String>,
    /// `window_changed` only.
    #[serde(default)]
    pub application_name: Option<String>,
    #[serde(default)]
    pub window_title: Option<String>,
    /// `drag` only: where the gesture started and where it ended.
    #[serde(default)]
    pub source: Option<InputTargetRef>,
    #[serde(default)]
    pub destination: Option<InputTargetRef>,
}

/// The resolved identity of the element an input landed on. `label` is the
/// element's title/description; `frame` is UI geometry in global top-left screen
/// points, rounded — not a pointer coordinate.
///
/// `value` is the element's content at the event's instant, which event-capture
/// v2 allows for typing and submit targets (the CAP-005 ban lapsed with the
/// local trust model). It is the primary content channel for anything composed
/// through an IME. The shim clips it and says so inline; nothing is re-clipped
/// here.
///
/// `Serialize` exists so the daemon can store this shape verbatim in the
/// vault's `input_events.target_json`: the store deliberately does not model
/// element identity, and re-encoding it into a second schema on the way in
/// would be a second thing to keep in step with the shim. Empty fields are
/// skipped — the round trip is lossless either way, and these rows are written
/// at interaction rate.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct InputTargetRef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Set by the shim when its secure guard suppressed content here, so a
    /// reader can tell "nothing was typed" from "not ours to keep".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secure: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<InputTargetFrame>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ancestors: Vec<InputAncestorRef>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
pub struct InputTargetFrame {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// An ancestor of a target. The subrole rides along because it is what the
/// shim's secure guard reads: a password field wrapped in a group can carry
/// `AXSecureTextField` on the wrapper.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct InputAncestorRef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subrole: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactKind {
    Screen,
    SystemAudio,
    Microphone,
    Accessibility,
    /// An R3 edge snapshot (`docs/input-events-and-t1-acts-plan.md`): the same
    /// accessibility payload as [`Self::Accessibility`], walked because the user
    /// changed scope rather than because the heartbeat came round.
    ///
    /// Deliberately **unpaired**: it carries no screenshot, and the pairing
    /// invariant that binds `Screen` to `Accessibility` does not apply to it. It
    /// still needs the same exclusion check, because it is a whole window's
    /// worth of text.
    AccessibilityEdge,
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
    #[error("capture shim stdout closed before a stopped event")]
    UnexpectedEof,
    #[error("capture shim did not stop within the graceful window and was killed")]
    StopTimeout,
}

struct RunningShim {
    child: Child,
    stdin: ChildStdin,
    reader: JoinHandle<()>,
    terminal_failed: Arc<AtomicBool>,
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
        let terminal_failed = Arc::new(AtomicBool::new(false));
        let reader_terminal_failed = Arc::clone(&terminal_failed);
        let reader = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut saw_stopped = false;
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
                        if matches!(&parsed, Ok(CaptureEvent::Failed { .. }) | Err(_)) {
                            reader_terminal_failed.store(true, Ordering::SeqCst);
                        }
                        if matches!(&parsed, Ok(CaptureEvent::Stopped)) {
                            saw_stopped = true;
                        }
                        if events_tx.send(parsed).await.is_err() {
                            break;
                        }
                    }
                    Ok(None) => {
                        // EOF wakes the single consumer, but it is only a
                        // normal terminal condition after the protocol-level
                        // `stopped` event. Otherwise the helper disappeared
                        // and capture must take the failed-recording path.
                        if !saw_stopped {
                            reader_terminal_failed.store(true, Ordering::SeqCst);
                            let _ = events_tx.send(Err(CaptureError::UnexpectedEof)).await;
                        }
                        break;
                    }
                    Err(error) => {
                        reader_terminal_failed.store(true, Ordering::SeqCst);
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
            terminal_failed,
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
        let event = {
            let mut events = self.events_rx.lock().await;
            events.recv().await
        }?;
        if matches!(&event, Ok(CaptureEvent::Failed { .. }) | Err(_)) {
            match self.stop_capture().await {
                Ok(()) | Err(CaptureError::NotRunning) => {}
                Err(error) => {
                    eprintln!("capture: failed helper cleanup completed with error: {error}");
                }
            }
            // Stopping finalizes audio and input observation. Those durable
            // tail events still belong to the active session, so replay them
            // before the original failure lets the daemon import them before
            // it closes the session. `Stopped` and any duplicate terminal
            // error belong only to this failed generation and must not become
            // the next helper's startup event.
            let durable_tail = {
                let mut events = self.events_rx.lock().await;
                let mut durable = Vec::new();
                while let Ok(tail_event) = events.try_recv() {
                    if matches!(
                        &tail_event,
                        Ok(
                            CaptureEvent::Artifact { .. }
                                | CaptureEvent::Warning { .. }
                                | CaptureEvent::InputEvents { .. }
                        )
                    ) {
                        durable.push(tail_event);
                    }
                }
                durable
            };
            let mut durable_tail = durable_tail.into_iter();
            if let Some(first) = durable_tail.next() {
                for tail_event in durable_tail.chain(std::iter::once(event)) {
                    if self.events_tx.send(tail_event).await.is_err() {
                        eprintln!("capture: event receiver closed while replaying failed tail");
                        break;
                    }
                }
                return Some(first);
            }
        }
        Some(event)
    }

    /// Removes events left by a stopped helper after its sole consumer has
    /// completed or been cancelled.
    ///
    /// The daemon calls this while its capture lifecycle gate excludes a new
    /// helper. It is deliberately separate from [`Self::stop_capture`]: final
    /// artifacts must remain available until the old session's consumer has
    /// either imported them or exhausted its failed-helper recovery budget.
    pub async fn discard_stopped_generation_events(&self) -> usize {
        let mut events = self.events_rx.lock().await;
        let mut discarded = 0;
        while events.try_recv().is_ok() {
            discarded += 1;
        }
        discarded
    }

    // @dec:bounded-shutdown — docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md
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
        let mut stop_error = write_command(&mut process.stdin, &ShimCommand::Stop)
            .await
            .err();
        drop(process.stdin);

        let mut status = None;
        if stop_error.is_none() {
            match timeout(STOP_GRACE_TIMEOUT, process.child.wait()).await {
                Ok(Ok(exited)) => status = Some(exited),
                Ok(Err(error)) => stop_error = Some(CaptureError::Io(error)),
                Err(_) => stop_error = Some(CaptureError::StopTimeout),
            }
        }
        if status.is_none() {
            if let Err(error) = process.child.start_kill()
                && stop_error.is_none()
            {
                stop_error = Some(CaptureError::Io(error));
            }
            match timeout(FORCE_REAP_TIMEOUT, process.child.wait()).await {
                Ok(Ok(exited)) => status = Some(exited),
                Ok(Err(error)) if stop_error.is_none() => {
                    stop_error = Some(CaptureError::Io(error));
                }
                Err(_) if stop_error.is_none() => {
                    stop_error = Some(CaptureError::StopTimeout);
                }
                Ok(Err(_)) | Err(_) => {}
            }
        }

        let healthy_exit = !process.terminal_failed.load(Ordering::SeqCst)
            && stop_error.is_none()
            && status
                .as_ref()
                .is_some_and(std::process::ExitStatus::success);
        let reader_result = if healthy_exit {
            // exit=0 closes stdout into a finite stream. The reader may still
            // be blocked on the bounded channel while the daemon imports an
            // earlier artifact; that backpressure is required durability work.
            process.reader.await
        } else {
            let Ok(reader_result) = timeout(READER_DRAIN_TIMEOUT, &mut process.reader).await else {
                process.reader.abort();
                // `abort` only schedules cancellation. Join it before returning
                // so this generation can never enqueue after a replacement
                // helper starts. The reader has only cancellation-safe Tokio
                // I/O/channel awaits, so the bounded work ended at `abort`.
                let _ = process.reader.await;
                if stop_error.is_none() {
                    stop_error = Some(CaptureError::StopTimeout);
                }
                return Err(stop_error.unwrap_or(CaptureError::StopTimeout));
            };
            reader_result
        };
        if let Err(error) = reader_result
            && stop_error.is_none()
        {
            stop_error = Some(CaptureError::Io(std::io::Error::other(format!(
                "capture event reader failed: {error}"
            ))));
        }
        if let Some(error) = stop_error {
            return Err(error);
        }
        let Some(status) = status else {
            return Err(CaptureError::StopTimeout);
        };
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

    #[cfg(unix)]
    #[tokio::test]
    async fn stuck_shim_is_killed_reaped_and_wakes_the_event_consumer() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("stuck-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nwhile IFS= read -r line; do :; done\nwhile :; do :; done\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        let started = std::time::Instant::now();
        let error = backend.stop_capture().await.unwrap_err();

        assert!(matches!(error, CaptureError::StopTimeout));
        assert!(started.elapsed() < Duration::from_secs(3));
        assert!(matches!(
            timeout(Duration::from_secs(1), backend.next_event()).await,
            Ok(Some(Err(CaptureError::UnexpectedEof)))
        ));
        assert!(matches!(
            backend.stop_capture().await,
            Err(CaptureError::NotRunning)
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn healthy_exit_drains_a_backpressured_reader_through_stopped() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("backpressured-shim.sh");
        let event_count = EVENT_BUFFER_CAPACITY + 2;
        let script = format!(
            "#!/bin/sh\nIFS= read -r line\nIFS= read -r line\ni=0\nwhile [ \"$i\" -lt {event_count} ]; do\n  printf '%s\\n' '{{\"event\":\"warning\",\"code\":\"test\",\"message\":\"queued\"}}'\n  i=$((i + 1))\ndone\nprintf '%s\\n' '{{\"event\":\"stopped\"}}'\n"
        );
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        let stopping_backend = Arc::clone(&backend);
        let stop = tokio::spawn(async move { stopping_backend.stop_capture().await });

        // Fill the real capacity-128 channel and leave the reader blocked for
        // longer than the retired successful-exit reader timeout.
        tokio::time::sleep(Duration::from_millis(650)).await;
        assert!(
            !stop.is_finished(),
            "a healthy reader must wait for consumer backpressure, not time out"
        );

        let mut warnings = 0;
        loop {
            let event = timeout(Duration::from_secs(5), backend.next_event())
                .await
                .expect("the finite healthy stream should keep draining")
                .expect("the reader should deliver an event");
            match event {
                Ok(CaptureEvent::Warning { .. }) => {
                    warnings += 1;
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                Ok(CaptureEvent::Stopped) => break,
                other => panic!("unexpected capture event: {other:?}"),
            }
        }

        assert_eq!(warnings, event_count);
        assert!(
            timeout(Duration::from_secs(5), stop)
                .await
                .expect("healthy stop should complete after the consumer drains")
                .expect("stop task should not panic")
                .is_ok(),
            "exit=0 plus protocol Stopped is a graceful stop"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stdout_eof_without_protocol_stopped_is_an_error() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("crashing-shim.sh");
        std::fs::write(&shim, "#!/bin/sh\nIFS= read -r line\nexit 0\n").unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            // Process launch and pipe delivery can be delayed substantially by
            // parallel linker/test load. This is only a test guard; production
            // stop/reap deadlines remain unchanged.
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Err(CaptureError::UnexpectedEof)))
        ));
        let _ = backend.stop_capture().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn terminal_failure_is_reaped_before_the_next_start() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("failed-but-alive-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}'\nprintf '%s\\n' '{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}'\nwhile IFS= read -r line; do\n  printf '%s\\n' '{\"event\":\"stopped\"}'\n  exit 0\ndone\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Failed { .. })))
        ));

        backend
            .start_capture()
            .await
            .expect("a terminal stream failure must not leave a stale running shim");
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        let _ = backend.stop_capture().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn terminal_failure_drains_durable_tail_before_reporting_failure() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("failed-with-final-artifact-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}'\nprintf '%s\\n' '{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}'\nwhile IFS= read -r line; do\n  printf '%s\\n' '{\"event\":\"artifact\",\"kind\":\"system_audio\",\"path\":\"/tmp/final.m4a\",\"content_type\":\"audio/mp4\",\"started_at_ms\":1,\"ended_at_ms\":2,\"byte_count\":3}'\n  printf '%s\\n' '{\"event\":\"stopped\"}'\n  exit 0\ndone\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Artifact {
                kind: ArtifactKind::SystemAudio,
                ..
            })))
        ));
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Failed { .. })))
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn terminal_failure_and_explicit_stop_converge_without_stale_events() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("controlled-failure-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}'\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *capture_screen*) printf '%s\\n' '{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}' ;;\n    *stop*) printf '%s\\n' '{\"event\":\"stopped\"}'; exit 0 ;;\n  esac\ndone\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        backend.capture_screen("trigger-failure").await.unwrap();

        let event_backend = Arc::clone(&backend);
        let failed_event = tokio::spawn(async move { event_backend.next_event().await });
        let stop_backend = Arc::clone(&backend);
        let explicit_stop = tokio::spawn(async move { stop_backend.stop_capture().await });
        let (failed_event, explicit_stop) = timeout(Duration::from_secs(5), async {
            tokio::join!(failed_event, explicit_stop)
        })
        .await
        .expect("failure cleanup and an explicit stop must not deadlock");

        assert!(matches!(
            failed_event.expect("event task should not panic"),
            Some(Ok(CaptureEvent::Failed { .. }))
        ));
        assert!(matches!(
            explicit_stop.expect("stop task should not panic"),
            Ok(()) | Err(CaptureError::NotRunning)
        ));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        backend.stop_capture().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn terminal_failure_force_reaps_an_uncooperative_helper() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("failed-and-stuck-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}'\nprintf '%s\\n' '{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}'\nexec sleep 3600\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        let started = std::time::Instant::now();
        assert!(matches!(
            timeout(Duration::from_secs(4), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Failed { .. })))
        ));
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "known-failed helper cleanup must stay within the failed path's bounds"
        );

        backend
            .start_capture()
            .await
            .expect("force-reaped failure must permit a new generation");
        let _ = backend.stop_capture().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn backpressured_failed_reader_cannot_leak_into_replacement() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("backpressured-failed-shim.sh");
        let event_count = EVENT_BUFFER_CAPACITY + 2;
        let script = format!(
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}}'\nprintf '%s\\n' '{{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}}'\ni=0\nwhile [ \"$i\" -lt {event_count} ]; do\n  printf '%s\\n' '{{\"event\":\"warning\",\"code\":\"test\",\"message\":\"queued\"}}'\n  i=$((i + 1))\ndone\nexec sleep 3600\n"
        );
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));

        let mut warnings = 0;
        loop {
            let event = timeout(Duration::from_secs(5), backend.next_event())
                .await
                .expect("the failed generation must stay bounded")
                .expect("the terminal failure must remain queued");
            match event {
                Ok(CaptureEvent::Warning { .. }) => warnings += 1,
                Ok(CaptureEvent::Failed { .. }) => break,
                other => panic!("unexpected failed-generation event: {other:?}"),
            }
        }
        assert_eq!(warnings, EVENT_BUFFER_CAPACITY);

        backend.start_capture().await.unwrap();
        assert!(matches!(
            timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        let _ = backend.stop_capture().await;
    }

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

    /// R3 edge snapshots ride the ordinary artifact event, with the same
    /// content type as a heartbeat tree and no `request_id`: nothing pulled
    /// them, and no screenshot is paired with them.
    #[test]
    fn parses_accessibility_edge_artifact_event() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"artifact","kind":"accessibility_edge","path":"/tmp/accessibility-edge-1.json","content_type":"application/vnd.afterray.ax+json","started_at_ms":1786698000000,"ended_at_ms":1786698000000,"byte_count":8192}"#,
        )
        .unwrap();
        assert_eq!(
            event,
            CaptureEvent::Artifact {
                kind: ArtifactKind::AccessibilityEdge,
                path: PathBuf::from("/tmp/accessibility-edge-1.json"),
                content_type: "application/vnd.afterray.ax+json".into(),
                started_at_ms: 1_786_698_000_000,
                ended_at_ms: 1_786_698_000_000,
                byte_count: 8192,
                request_id: None,
            }
        );
    }

    #[test]
    fn parses_input_events_event() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"input_events","dropped":2,"events":[
                {"at_ms":100,"kind":"burst","end_ms":2100,"count":34,"ended_with":"return",
                 "bundle_identifier":"com.electron.lark",
                 "target":{"role":"AXTextArea","label":"Message 赵亮",
                           "frame":{"x":831,"y":899,"width":541,"height":22},
                           "ancestors":[{"role":"AXGroup","label":null}]}},
                {"at_ms":150,"kind":"click","bundle_identifier":"com.electron.lark"}
            ]}"#,
        )
        .unwrap();
        let CaptureEvent::InputEvents { events, dropped } = event else {
            panic!("expected input_events, got {event:?}");
        };
        assert_eq!(dropped, 2);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "burst");
        assert_eq!(events[0].count, Some(34));
        assert_eq!(events[0].ended_with.as_deref(), Some("return"));
        let target = events[0].target.as_ref().expect("burst target");
        assert_eq!(target.role.as_deref(), Some("AXTextArea"));
        assert_eq!(
            target.frame,
            Some(InputTargetFrame {
                x: 831,
                y: 899,
                width: 541,
                height: 22
            })
        );
        // A minimal record parses with every optional field absent.
        assert_eq!(events[1].kind, "click");
        assert_eq!(events[1].target, None);
    }

    /// The event-capture v2 vocabulary (docs/event-capture-v2-plan.md §2): a
    /// typing run with its characters and the field's composed value, a drag
    /// with both ends, and an explicit window change.
    #[test]
    fn parses_the_v2_event_vocabulary() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"input_events","events":[
                {"at_ms":100,"kind":"burst","end_ms":2100,"count":12,
                 "bundle_identifier":"com.electron.lark","text":"wsm tongyini",
                 "target":{"role":"AXTextArea","subrole":null,"label":"Message 赵亮",
                           "value":"我说得对吗 [truncated to visible range]",
                           "ancestors":[{"role":"AXGroup","subrole":null,"label":null}]}},
                {"at_ms":3000,"kind":"drag","end_ms":3400,"bundle_identifier":"com.apple.finder",
                 "source":{"role":"AXCell","label":"report.pdf"},
                 "destination":{"role":"AXRow","label":"Archive"}},
                {"at_ms":4000,"kind":"window_changed","bundle_identifier":"dev.zed.Zed",
                 "application_name":"Zed","window_title":"main.rs — afterray"}
            ]}"#,
        )
        .unwrap();
        let CaptureEvent::InputEvents { events, dropped } = event else {
            panic!("expected input_events, got {event:?}");
        };
        assert_eq!(dropped, 0);

        // The keystream is pinyin and the sentence only exists in the value —
        // which is why the value is the primary channel, not the fallback.
        assert_eq!(events[0].text.as_deref(), Some("wsm tongyini"));
        let typed = events[0].target.as_ref().expect("burst target");
        assert!(typed.value.as_deref().unwrap().starts_with("我说得对吗"));
        assert_eq!(typed.secure, None);

        // A drag is a causal edge; one end of it says nothing.
        assert_eq!(events[1].kind, "drag");
        assert_eq!(
            events[1].source.as_ref().and_then(|end| end.label.as_deref()),
            Some("report.pdf")
        );
        assert_eq!(
            events[1]
                .destination
                .as_ref()
                .and_then(|end| end.label.as_deref()),
            Some("Archive")
        );
        assert_eq!(events[1].target, None);

        assert_eq!(events[2].kind, "window_changed");
        assert_eq!(events[2].application_name.as_deref(), Some("Zed"));
        assert_eq!(events[2].window_title.as_deref(), Some("main.rs — afterray"));
    }

    /// The secure guard lives in the shim, at the source: by the time a record
    /// reaches this parser the password is already not in it. All a reader sees
    /// is a burst that kept its count and carries neither `text` nor a target
    /// `value` — and says so with `secure`. There is nothing here to re-check,
    /// and a parser that tried would be guessing about a field it never saw.
    #[test]
    fn a_guarded_typing_run_arrives_without_content() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"input_events","events":[
                {"at_ms":100,"kind":"burst","end_ms":1200,"count":18,
                 "bundle_identifier":"com.apple.Safari",
                 "target":{"role":"AXTextField","subrole":"AXSecureTextField",
                           "label":"Password","secure":true}}
            ]}"#,
        )
        .unwrap();
        let CaptureEvent::InputEvents { events, .. } = event else {
            panic!("expected input_events, got {event:?}");
        };
        assert_eq!(events[0].count, Some(18), "that typing happened is kept");
        assert_eq!(events[0].text, None);
        let target = events[0].target.as_ref().expect("target");
        assert_eq!(target.value, None);
        assert_eq!(target.secure, Some(true));
    }

    /// A batch from the shim as it was before event-capture v2 — no `text`, no
    /// `subrole`, no drag ends. The daemon can be newer than the helper it
    /// spawns during an update, and an old batch must not become a parse error.
    #[test]
    fn parses_a_pre_v2_batch() {
        let event: CaptureEvent = serde_json::from_str(
            r#"{"event":"input_events","dropped":1,"events":[
                {"at_ms":100,"kind":"burst","end_ms":2100,"count":34,"ended_with":"return",
                 "bundle_identifier":"com.electron.lark",
                 "target":{"role":"AXTextArea","label":"Message",
                           "frame":{"x":8,"y":9,"width":5,"height":2},
                           "ancestors":[{"role":"AXGroup","label":"Sidebar"}]}},
                {"at_ms":150,"kind":"command","command":"cmd-c"}
            ]}"#,
        )
        .unwrap();
        let CaptureEvent::InputEvents { events, dropped } = event else {
            panic!("expected input_events, got {event:?}");
        };
        assert_eq!(dropped, 1);
        let target = events[0].target.as_ref().expect("burst target");
        assert_eq!(target.subrole, None);
        assert_eq!(target.value, None);
        assert_eq!(target.secure, None);
        assert_eq!(target.ancestors[0].subrole, None);
        assert_eq!(events[0].text, None);
        assert_eq!(events[1].command.as_deref(), Some("cmd-c"));
    }

    /// The daemon stores the target verbatim in `input_events.target_json`, so
    /// what the shim resolved has to survive the round trip — including the v2
    /// fields, which nothing between here and the vault re-derives.
    #[test]
    fn a_v2_target_round_trips_through_serialization() {
        let target = InputTargetRef {
            role: Some("AXTextArea".to_owned()),
            subrole: Some("AXSearchField".to_owned()),
            label: Some("Search".to_owned()),
            value: Some("afterray vault".to_owned()),
            secure: None,
            frame: None,
            ancestors: vec![InputAncestorRef {
                role: Some("AXGroup".to_owned()),
                subrole: None,
                label: None,
            }],
        };
        let json = serde_json::to_string(&target).unwrap();
        assert!(!json.contains("secure"), "absent fields stay absent");
        assert!(!json.contains("frame"));
        assert_eq!(
            serde_json::from_str::<InputTargetRef>(&json).unwrap(),
            target
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
