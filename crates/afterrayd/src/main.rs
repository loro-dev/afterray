mod agent;
mod ask;
mod gop_packer;
mod memory;
mod tools;

use afterray_codec::{CONTENT_TYPE_IVF_AV01, DEFAULT_THUMBNAIL_MAX_EDGE, still_thumbnail};
use afterray_models::{
    JobState, LlmRouterAdapter, LlmRuntimeConfig, ModelAdapter, ModelCapability, ModelInput,
    ModelOutput, ModelQueue, ProcessAdapter, ProcessAdapterConfig, QueueConfig, download_packs,
    library, model_directory, probe_llm, specs_for_download,
};
use afterray_platform_macos::{
    ArtifactKind, CaptureConfig, CaptureError, CaptureEvent, MacOsCaptureBackend,
    apply_background_qos,
};
use afterray_protocol::{
    AppSettings, ArtifactPayload, GopReadMode, HistoryScope, LlmProvider, ModelDownloadProgress,
    PROTOCOL_VERSION, PackStatus, RecordingState, Request, Response, SearchHit, Status,
    local_calendar_day_bounds_ms,
};
use afterray_store::{MacOsKeychainProvider, StoreError, Vault, VaultConfig, fuse_search_results};
use anyhow::Context;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Mutex,
    task::JoinHandle,
};
use uuid::Uuid;

fn default_socket_path() -> PathBuf {
    std::env::var_os("AFTERRAY_SOCKET").map_or_else(
        || std::env::temp_dir().join("afterray-v0.sock"),
        PathBuf::from,
    )
}

fn clear_stale_capture_files(staging_dir: &Path) -> std::io::Result<usize> {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    std::fs::create_dir_all(staging_dir)?;
    #[cfg(unix)]
    std::fs::set_permissions(staging_dir, std::fs::Permissions::from_mode(0o700))?;
    let mut removed = 0;
    for entry in std::fs::read_dir(staging_dir)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_file() || file_type.is_symlink() {
            std::fs::remove_file(entry.path())?;
            removed += 1;
        }
    }
    Ok(removed)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let socket = default_socket_path();
    if socket.exists() {
        std::fs::remove_file(&socket).context("remove stale daemon socket")?;
    }
    let listener = UnixListener::bind(&socket).context("bind daemon socket")?;

    let mut vault_config = VaultConfig::default();
    if let Some(path) = std::env::var_os("AFTERRAY_DATA_DIR") {
        vault_config.data_dir = PathBuf::from(path);
    }
    if let Ok(value) = std::env::var("AFTERRAY_MAX_UNSTARRED_MOMENTS") {
        vault_config.max_unstarred_moments = value.parse().context("invalid retention limit")?;
    }
    let staging_dir = vault_config.data_dir.join("capture-staging");
    let removed_staging_files = clear_stale_capture_files(&staging_dir)?;
    if removed_staging_files > 0 {
        eprintln!("removed {removed_staging_files} stale capture staging file(s)");
    }
    let persisted = load_persisted_settings(&vault_config.data_dir);
    let llm_config = Arc::new(std::sync::Mutex::new(resolve_llm_config(&persisted)));
    let data_dir = vault_config.data_dir.clone();
    let store = Arc::new(Vault::open(vault_config, &MacOsKeychainProvider)?);
    let repaired_sessions = store.close_orphaned_sessions_sync(now_ms())?;
    if repaired_sessions > 0 {
        eprintln!("closed {repaired_sessions} session(s) left open by an earlier daemon");
    }
    let shim_path = std::env::var_os("AFTERRAY_CAPTURE_SHIM").map_or_else(
        || PathBuf::from("apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim"),
        PathBuf::from,
    );
    let mut capture_config = CaptureConfig::new(shim_path, staging_dir.clone());
    capture_config.record_audio = persisted.record_audio;
    let capture = MacOsCaptureBackend::new(capture_config);

    let worker_path = std::env::var_os("AFTERRAY_MODEL_WORKER").map_or_else(
        || PathBuf::from("target/release/afterray-model-worker"),
        PathBuf::from,
    );
    let native_worker_path = std::env::var_os("AFTERRAY_NATIVE_MODEL_WORKER").map_or_else(
        || PathBuf::from(".build/release/afterray-native-model-worker"),
        PathBuf::from,
    );
    let models = ModelQueue::new(
        local_model_adapters(native_worker_path, worker_path, Arc::clone(&llm_config)),
        QueueConfig::default(),
    )?;

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let migration_store = Arc::clone(&store);
    let packer = Arc::new(gop_packer::GopPacker::new(
        gop_packer::GopPackerConfig::from_env(),
    ));
    let capture_busy = Arc::new(AtomicBool::new(false));
    let last_capture_ms = Arc::new(AtomicI64::new(0));
    let recording_active = Arc::new(AtomicBool::new(false));
    let state = Arc::new(AppState {
        store,
        capture,
        models,
        recording: Mutex::new(RecordingRuntime::default()),
        download: std::sync::Mutex::new(None),
        capture_interval: Duration::from_secs(
            std::env::var("AFTERRAY_CAPTURE_INTERVAL_SECONDS")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(10),
        ),
        data_dir,
        shutdown: shutdown_tx,
        packer,
        capture_busy,
        last_capture_ms,
        recording_active,
        excluded_bundle_ids: std::sync::Mutex::new(persisted.excluded_bundle_ids.clone()),
        memories: std::sync::Mutex::new(memory::MemoryRuntime::default()),
        llm_config,
    });
    println!("afterrayd listening on {}", socket.display());
    tokio::task::spawn_blocking(move || match migration_store.run_artifact_maintenance() {
        Ok(0) => {}
        Ok(count) => eprintln!("migrated {count} legacy artifact(s) in the background"),
        Err(error) => eprintln!("background artifact maintenance paused: {error}"),
    });
    spawn_gop_packer(Arc::clone(&state));

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    if let Err(error) = handle(stream, state).await {
                        eprintln!("client error: {error:#}");
                    }
                });
            }
            () = &mut shutdown => break,
            changed = shutdown_rx.changed() => {
                if changed.is_ok() && *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }

    let response = record_stop(&state, None).await;
    if !response.ok {
        eprintln!(
            "could not finish the active session during shutdown: {}",
            response.error.as_deref().unwrap_or("unknown error")
        );
    }
    if let Err(error) = clear_stale_capture_files(&staging_dir) {
        eprintln!("could not clear capture staging during shutdown: {error}");
    }
    drop(listener);
    let _ = std::fs::remove_file(&socket);
    Ok(())
}

#[cfg(unix)]
async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};

    let mut terminate = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    tokio::select! {
        result = tokio::signal::ctrl_c() => {
            if let Err(error) = result {
                eprintln!("Ctrl-C handler failed: {error}");
            }
        }
        _ = terminate.recv() => {}
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        eprintln!("Ctrl-C handler failed: {error}");
    }
}

fn local_model_adapters(
    native_worker: PathBuf,
    general_worker: PathBuf,
    llm_config: Arc<std::sync::Mutex<LlmRuntimeConfig>>,
) -> Vec<Arc<dyn ModelAdapter>> {
    let llm = Arc::new(LlmRouterAdapter::new(
        ProcessAdapter::new(ProcessAdapterConfig::new(
            "llama-llm",
            ModelCapability::Llm,
            general_worker.clone(),
        )),
        llm_config,
    ));
    vec![
        Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
            "vision-ocr",
            ModelCapability::Ocr,
            native_worker,
        ))) as Arc<dyn ModelAdapter>,
        Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
            "qwen3-asr",
            ModelCapability::Asr,
            general_worker.clone(),
        ))),
        Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
            "llama-embedding",
            ModelCapability::Embedding,
            general_worker,
        ))),
        llm,
    ]
}

struct AppState {
    store: Arc<Vault>,
    capture: Arc<MacOsCaptureBackend>,
    models: ModelQueue,
    recording: Mutex<RecordingRuntime>,
    download: std::sync::Mutex<Option<ModelDownloadProgress>>,
    capture_interval: Duration,
    data_dir: PathBuf,
    shutdown: tokio::sync::watch::Sender<bool>,
    packer: Arc<gop_packer::GopPacker>,
    capture_busy: Arc<AtomicBool>,
    last_capture_ms: Arc<AtomicI64>,
    recording_active: Arc<AtomicBool>,
    excluded_bundle_ids: std::sync::Mutex<Vec<String>>,
    memories: std::sync::Mutex<memory::MemoryRuntime>,
    llm_config: Arc<std::sync::Mutex<LlmRuntimeConfig>>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct PersistedSettings {
    #[serde(default = "default_record_audio")]
    record_audio: bool,
    #[serde(default)]
    excluded_bundle_ids: Vec<String>,
    #[serde(default)]
    llm_provider: LlmProvider,
    #[serde(default)]
    llm_base_url: String,
    #[serde(default)]
    llm_model: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    llm_api_key: String,
}

const fn default_record_audio() -> bool {
    true
}

impl Default for PersistedSettings {
    fn default() -> Self {
        Self {
            record_audio: true,
            excluded_bundle_ids: Vec::new(),
            llm_provider: LlmProvider::Builtin,
            llm_base_url: String::new(),
            llm_model: String::new(),
            llm_api_key: String::new(),
        }
    }
}

#[derive(Default)]
struct RecordingRuntime {
    active_session_id: Option<String>,
    captured_frame: bool,
    scheduler: Option<JoinHandle<()>>,
    event_consumer: Option<JoinHandle<()>>,
}

fn recording_state_of(runtime: &RecordingRuntime) -> RecordingState {
    if runtime.active_session_id.is_none() {
        RecordingState::Idle
    } else if runtime.captured_frame {
        RecordingState::Recording
    } else {
        RecordingState::Waiting
    }
}

async fn handle(stream: UnixStream, state: Arc<AppState>) -> anyhow::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        match serde_json::from_str::<Request>(&line) {
            Ok(Request::ReadArtifact { artifact_id }) => {
                write_artifact_response(&mut write, read_still_artifact(&state, &artifact_id))
                    .await?;
            }
            Ok(Request::ReadGopSegment { segment_id }) => {
                write_artifact_response(&mut write, state.store.read_gop_artifact(&segment_id))
                    .await?;
            }
            Ok(Request::ReadGopFrame {
                segment_id,
                index,
                mode,
            }) => {
                write_artifact_response(
                    &mut write,
                    gop_packer::read_gop_frame(&state.store, &segment_id, index, mode),
                )
                .await?;
            }
            Ok(Request::ReadThumbnail {
                moment_id,
                max_edge,
            }) => {
                write_artifact_response(
                    &mut write,
                    read_moment_thumbnail(&state.store, &moment_id, max_edge),
                )
                .await?;
            }
            Ok(request) => {
                write_json_response(&mut write, &dispatch(request, &state).await).await?;
            }
            Err(error) => {
                write_json_response(
                    &mut write,
                    &Response::failure(format!("invalid request: {error}")),
                )
                .await?;
            }
        }
    }
    Ok(())
}

async fn write_json_response(
    write: &mut tokio::net::unix::OwnedWriteHalf,
    response: &Response,
) -> anyhow::Result<()> {
    let mut encoded = serde_json::to_vec(response)?;
    encoded.push(b'\n');
    write.write_all(&encoded).await?;
    Ok(())
}

async fn write_artifact_response(
    write: &mut tokio::net::unix::OwnedWriteHalf,
    result: Result<ArtifactPayload, StoreError>,
) -> anyhow::Result<()> {
    match result {
        Ok(payload) => {
            write.write_all(&payload.header_line()?).await?;
            write.write_all(&payload.bytes).await?;
        }
        Err(error) => {
            write_json_response(write, &Response::failure(error.to_string())).await?;
        }
    }
    Ok(())
}

async fn dispatch(request: Request, state: &Arc<AppState>) -> Response {
    match request {
        Request::Ping => Response::success(serde_json::json!({"pong": true})),
        Request::Status => {
            let recording = state.recording.lock().await;
            Response::success(Status {
                daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
                protocol_version: PROTOCOL_VERSION,
                schema_version: afterray_store::SCHEMA_VERSION,
                recording_state: recording_state_of(&recording),
                active_session_id: recording.active_session_id.clone(),
            })
        }
        Request::RecordStart => record_start(state).await,
        Request::RecordStop { reason } => record_stop(state, reason.as_deref()).await,
        Request::SessionsList => into_response(state.store.sessions_sync()),
        Request::TimelineList => into_response(state.store.timeline_sync()),
        Request::TimelineSince { since_ms } => {
            into_response(state.store.timeline_since_sync(since_ms))
        }
        Request::MomentsList { session_id } => into_response(state.store.moments_sync(&session_id)),
        Request::RecallWindow {
            session_id,
            center_ms,
            limit,
        } => match state.store.moments_sync(&session_id) {
            Ok(mut moments) => {
                moments.sort_by_key(|moment| moment.captured_at_ms.abs_diff(center_ms));
                moments.truncate(limit.clamp(1, 500));
                moments.sort_by_key(|moment| moment.captured_at_ms);
                Response::success(moments)
            }
            Err(error) => Response::failure(error.to_string()),
        },
        Request::ReadArtifact { .. }
        | Request::ReadGopSegment { .. }
        | Request::ReadGopFrame { .. }
        | Request::ReadThumbnail { .. } => Response::failure(
            "artifact reads are framed as a JSON header plus raw bytes and are handled separately",
        ),
        Request::PackStatus => pack_status(state),
        Request::GopShow { segment_id } => into_response(state.store.gop_segment_view(&segment_id)),
        Request::FavoriteSet { .. } => Response::failure("favorites are disabled"),
        Request::Search {
            query,
            limit,
            from_ms,
            to_ms,
        } => {
            match search_hits(&state.store, &state.models, &query, limit.clamp(1, 100)).await {
                Ok(mut hits) => {
                    if let (Some(from), Some(to)) = (from_ms, to_ms) {
                        let (from, to) = if from <= to { (from, to) } else { (to, from) };
                        hits.retain(|hit| hit.captured_at_ms >= from && hit.captured_at_ms <= to);
                    }
                    Response::success(hits)
                }
                Err(error) => Response::failure(error.to_string()),
            }
        }
        Request::MomentGet { moment_id } => match tools::moment_detail(&state.store, &moment_id) {
            Ok(moment) => Response::success(moment),
            Err(error) => Response::failure(error),
        },
        Request::EvidenceOcr { moment_id } => match tools::ocr_evidence(&state.store, &moment_id) {
            Ok(evidence) => Response::success(evidence),
            Err(error) => Response::failure(error),
        },
        Request::EvidenceAx {
            moment_id,
            digest_only,
        } => match tools::ax_evidence(&state.store, &moment_id, digest_only) {
            Ok(evidence) => Response::success(evidence),
            Err(error) => Response::failure(error),
        },
        Request::ActivitySpans {
            from_ms,
            to_ms,
            limit,
        } => into_response(
            state
                .store
                .activity_spans(from_ms, to_ms, limit.clamp(1, 500)),
        ),
        Request::ModelsStatus => Response::success(model_library(state)),
        Request::JobsList => Response::success(state.models.list().await),
        Request::JobRetry { job_id } => match state.models.retry(&job_id).await {
            Ok(snapshot) => Response::success(snapshot),
            Err(error) => Response::failure(error.to_string()),
        },
        Request::Summarize { session_id } => summarize(state, &session_id).await,
        Request::Ask {
            question,
            from_ms,
            to_ms,
        } => {
            let llm_ready = ensure_remote_llm_model(state).await;
            ask::handle_ask(
                &state.store,
                &state.models,
                &question,
                from_ms,
                to_ms,
                now_ms(),
                llm_ready,
            )
            .await
        }
        Request::Settings => Response::success(current_settings(state)),
        Request::UpdateSettings {
            record_audio,
            excluded_bundle_ids,
            llm_provider,
            llm_base_url,
            llm_model,
            llm_api_key,
        } => {
            update_settings(
                state,
                record_audio,
                excluded_bundle_ids,
                llm_provider,
                llm_base_url,
                llm_model,
                llm_api_key,
            )
            .await
        }
        Request::LlmProbe {
            provider,
            base_url,
        } => {
            let config = current_llm_config(state);
            let provider = provider.unwrap_or(config.provider);
            let base_url = base_url
                .filter(|value| !value.trim().is_empty())
                .or_else(|| {
                    let resolved = config.resolved_base_url();
                    if resolved.is_empty() {
                        None
                    } else {
                        Some(resolved)
                    }
                });
            Response::success(
                probe_llm(
                    provider,
                    base_url.as_deref(),
                    config.api_key.as_deref(),
                )
                .await,
            )
        }
        Request::ClearHistory { scope } => clear_history(state, scope).await,
        Request::MemoriesList {
            from_ms,
            to_ms,
            limit,
        } => into_response(state.store.memories(from_ms, to_ms, limit.clamp(1, 200))),
        Request::DownloadModels { pack_id } => download_models(state, pack_id.as_deref()).await,
        Request::Shutdown => {
            let _ = state.shutdown.send(true);
            Response::success(serde_json::json!({
                "stopping": true,
                "pid": std::process::id(),
            }))
        }
    }
}

async fn record_start(state: &Arc<AppState>) -> Response {
    let _ = state.store.end_open_idle_spans(now_ms());
    let mut recording = state.recording.lock().await;
    if let Some(id) = &recording.active_session_id {
        eprintln!("record_start: already recording session {id}");
        return Response::success(serde_json::json!({"session_id": id, "already_recording": true}));
    }
    let session = match state.store.create_session_sync(now_ms()) {
        Ok(session) => session,
        Err(error) => {
            eprintln!("record_start: failed to create session: {error}");
            return Response::failure(error.to_string());
        }
    };
    eprintln!(
        "record_start: session {} audio={}",
        session.id,
        state.capture.record_audio()
    );
    recording.active_session_id = Some(session.id.clone());
    recording.captured_frame = false;
    state.recording_active.store(true, Ordering::SeqCst);
    drop(recording);
    if let Err(error) = start_capture_runtime(state, session.id.clone()).await {
        eprintln!("record_start: capture runtime failed: {error}");
        let _ = state.store.end_session_sync(&session.id, now_ms());
        let mut recording = state.recording.lock().await;
        if recording.active_session_id.as_deref() == Some(session.id.as_str()) {
            recording.active_session_id = None;
        }
        state.recording_active.store(false, Ordering::SeqCst);
        return Response::failure(error);
    }
    eprintln!("record_start: session {} is recording", session.id);
    Response::success(serde_json::json!({"session": session}))
}

async fn start_capture_runtime(state: &Arc<AppState>, session_id: String) -> Result<(), String> {
    const READY_TIMEOUT: Duration = Duration::from_secs(30);
    state.capture_busy.store(true, Ordering::SeqCst);
    if let Err(error) = state.capture.start_capture().await {
        state.capture_busy.store(false, Ordering::SeqCst);
        eprintln!("capture runtime: start_capture failed: {error}");
        return Err(error.to_string());
    }
    eprintln!(
        "capture runtime: waiting up to {}s for shim ready (session {session_id})",
        READY_TIMEOUT.as_secs()
    );
    match tokio::time::timeout(READY_TIMEOUT, state.capture.next_event()).await {
        Ok(Some(Ok(CaptureEvent::Ready {
            display_id,
            width,
            height,
        }))) => {
            eprintln!("capture runtime: shim ready display={display_id} {width}x{height}");
        }
        Ok(Some(Ok(CaptureEvent::Failed { code, message }))) => {
            state.capture_busy.store(false, Ordering::SeqCst);
            let _ = state.capture.stop_capture().await;
            return Err(format!("capture startup failed [{code}]: {message}"));
        }
        Ok(Some(Ok(event))) => {
            state.capture_busy.store(false, Ordering::SeqCst);
            let _ = state.capture.stop_capture().await;
            return Err(format!(
                "capture helper returned {event:?} before it was ready"
            ));
        }
        Ok(Some(Err(error))) => {
            state.capture_busy.store(false, Ordering::SeqCst);
            let _ = state.capture.stop_capture().await;
            return Err(error.to_string());
        }
        Ok(None) => {
            state.capture_busy.store(false, Ordering::SeqCst);
            let _ = state.capture.stop_capture().await;
            return Err("capture helper exited before it was ready".to_owned());
        }
        Err(_) => {
            state.capture_busy.store(false, Ordering::SeqCst);
            let _ = state.capture.stop_capture().await;
            return Err("capture helper did not become ready within 30 seconds".to_owned());
        }
    }
    state.capture_busy.store(false, Ordering::SeqCst);

    let capture = Arc::clone(&state.capture);
    let interval = state.capture_interval;
    let capture_busy = Arc::clone(&state.capture_busy);
    let last_capture_ms = Arc::clone(&state.last_capture_ms);
    let scheduler = tokio::spawn(async move {
        let mut timer = tokio::time::interval(interval);
        loop {
            timer.tick().await;
            capture_busy.store(true, Ordering::SeqCst);
            last_capture_ms.store(now_ms(), Ordering::SeqCst);
            let request_id = Uuid::now_v7().to_string();
            let result = capture.capture_screen(&request_id).await;
            capture_busy.store(false, Ordering::SeqCst);
            if let Err(error) = result {
                eprintln!("capture request failed: {error}");
                break;
            }
        }
    });

    let event_state = Arc::clone(state);
    let consumer_session = session_id.clone();
    let event_consumer = tokio::spawn(async move {
        consume_capture_events(event_state, consumer_session).await;
    });
    let mut recording = state.recording.lock().await;
    if recording.active_session_id.as_deref() != Some(session_id.as_str()) {
        scheduler.abort();
        let _ = state.capture.stop_capture().await;
        return Ok(());
    }
    recording.scheduler = Some(scheduler);
    recording.event_consumer = Some(event_consumer);
    Ok(())
}

async fn restart_capture_runtime(state: &Arc<AppState>) -> Result<(), String> {
    let (session_id, consumer) = {
        let mut recording = state.recording.lock().await;
        let Some(session_id) = recording.active_session_id.clone() else {
            return Ok(());
        };
        if let Some(scheduler) = recording.scheduler.take() {
            scheduler.abort();
        }
        (session_id, recording.event_consumer.take())
    };
    match state.capture.stop_capture().await {
        Ok(()) | Err(CaptureError::NotRunning) => {}
        Err(error) => return Err(error.to_string()),
    }
    if let Some(consumer) = consumer {
        let _ = tokio::time::timeout(Duration::from_secs(12), consumer).await;
    }
    start_capture_runtime(state, session_id).await
}

fn current_llm_config(state: &AppState) -> LlmRuntimeConfig {
    state
        .llm_config
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

fn llm_is_ready(state: &AppState) -> bool {
    ask::llm_ready(&model_library(state), &current_llm_config(state))
}

/// Ollama Settings can leave `llm_model` empty after a probe fills only the UI
/// draft. Resolve a recommended chat model and persist it so Ask can run.
async fn ensure_remote_llm_model(state: &AppState) -> bool {
    let config = current_llm_config(state);
    if ask::llm_ready(&model_library(state), &config) {
        return true;
    }
    if config.provider != LlmProvider::Ollama || !config.chat_model().is_empty() {
        return false;
    }
    let origin = config.resolved_base_url();
    let probe = probe_llm(
        config.provider,
        Some(origin.as_str()).filter(|value| !value.is_empty()),
        config.api_key.as_deref(),
    )
    .await;
    let Some(model) = probe
        .recommended_model
        .filter(|value| !value.trim().is_empty())
    else {
        return false;
    };
    {
        let mut llm = state
            .llm_config
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if llm.model.trim().is_empty() {
            llm.model = model;
        }
    }
    if let Err(error) = persist_current_settings(state) {
        eprintln!("could not persist discovered Ollama model: {error}");
    }
    llm_is_ready(state)
}

fn current_settings(state: &AppState) -> AppSettings {
    let llm = current_llm_config(state);
    AppSettings {
        data_dir: state.data_dir.display().to_string(),
        model_dir: model_directory().display().to_string(),
        record_audio: state.capture.record_audio(),
        capture_interval_seconds: state.capture_interval.as_secs(),
        excluded_bundle_ids: state
            .excluded_bundle_ids
            .lock()
            .map(|ids| ids.clone())
            .unwrap_or_default(),
        llm_provider: llm.provider,
        llm_base_url: llm.base_url,
        llm_model: llm.model,
        llm_api_key_set: llm
            .api_key
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
    }
}

fn persist_current_settings(state: &AppState) -> std::io::Result<()> {
    let llm = current_llm_config(state);
    save_persisted_settings(
        &state.data_dir,
        &PersistedSettings {
            record_audio: state.capture.record_audio(),
            excluded_bundle_ids: state
                .excluded_bundle_ids
                .lock()
                .map(|ids| ids.clone())
                .unwrap_or_default(),
            llm_provider: llm.provider,
            llm_base_url: llm.base_url,
            llm_model: llm.model,
            llm_api_key: llm.api_key.unwrap_or_default(),
        },
    )
}

async fn update_settings(
    state: &Arc<AppState>,
    record_audio: Option<bool>,
    excluded_bundle_ids: Option<Vec<String>>,
    llm_provider: Option<LlmProvider>,
    llm_base_url: Option<String>,
    llm_model: Option<String>,
    llm_api_key: Option<String>,
) -> Response {
    if let Some(enabled) = record_audio {
        let previous = state.capture.record_audio();
        state.capture.set_record_audio(enabled);
        if let Err(error) = persist_current_settings(state) {
            state.capture.set_record_audio(previous);
            return Response::failure(format!("could not save settings: {error}"));
        }
        if previous != enabled
            && let Err(error) = restart_capture_runtime(state).await
        {
            return Response::failure(format!(
                "audio preference saved, but capture could not restart: {error}"
            ));
        }
    }
    if let Some(ids) = excluded_bundle_ids {
        let cleaned = normalize_bundle_ids(ids);
        {
            let mut excluded = state
                .excluded_bundle_ids
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            *excluded = cleaned;
        }
        if let Err(error) = persist_current_settings(state) {
            return Response::failure(format!("could not save settings: {error}"));
        }
    }
    if llm_provider.is_some()
        || llm_base_url.is_some()
        || llm_model.is_some()
        || llm_api_key.is_some()
    {
        {
            let mut llm = state
                .llm_config
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(provider) = llm_provider {
                llm.provider = provider;
            }
            if let Some(base_url) = llm_base_url {
                llm.base_url = base_url.trim().to_owned();
            }
            if let Some(model) = llm_model {
                llm.model = model.trim().to_owned();
            }
            if let Some(api_key) = llm_api_key {
                let trimmed = api_key.trim();
                llm.api_key = if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_owned())
                };
            }
        }
        if let Err(error) = persist_current_settings(state) {
            return Response::failure(format!("could not save assistant settings: {error}"));
        }
    }
    Response::success(current_settings(state))
}

fn resolve_llm_config(persisted: &PersistedSettings) -> LlmRuntimeConfig {
    LlmRuntimeConfig {
        provider: std::env::var("AFTERRAY_LLM_PROVIDER")
            .ok()
            .as_deref()
            .and_then(LlmProvider::parse)
            .unwrap_or(persisted.llm_provider),
        base_url: env_nonempty("AFTERRAY_LLM_BASE_URL")
            .unwrap_or_else(|| persisted.llm_base_url.clone()),
        model: env_nonempty("AFTERRAY_LLM_CHAT_MODEL").unwrap_or_else(|| persisted.llm_model.clone()),
        api_key: env_nonempty("AFTERRAY_LLM_API_KEY").or_else(|| {
            let key = persisted.llm_api_key.trim();
            if key.is_empty() {
                None
            } else {
                Some(key.to_owned())
            }
        }),
    }
}

fn env_nonempty(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn normalize_bundle_ids(ids: Vec<String>) -> Vec<String> {
    let mut cleaned = ids
        .into_iter()
        .map(|id| id.trim().to_owned())
        .filter(|id| !id.is_empty())
        .collect::<Vec<_>>();
    cleaned.sort();
    cleaned.dedup();
    cleaned
}

fn is_excluded_bundle(state: &AppState, bundle_id: Option<&str>) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    state
        .excluded_bundle_ids
        .lock()
        .map(|ids| ids.iter().any(|id| id == bundle_id))
        .unwrap_or(false)
}

async fn clear_history(state: &Arc<AppState>, scope: HistoryScope) -> Response {
    let now = now_ms();
    let (from_ms, to_ms) = match scope {
        HistoryScope::LastHour => (now.saturating_sub(60 * 60 * 1000), now),
        HistoryScope::Today => local_calendar_day_bounds_ms(now),
        HistoryScope::All => (0, now),
    };
    memory::flush(
        &state.store,
        &state.models,
        &state.memories,
        llm_is_ready(state),
    )
    .await;
    match state.store.delete_history(from_ms, to_ms) {
        Ok(deleted) => Response::success(serde_json::json!({
            "scope": scope,
            "deleted": deleted,
            "from_ms": from_ms,
            "to_ms": to_ms,
        })),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn settings_path(data_dir: &Path) -> PathBuf {
    data_dir.join("settings.json")
}

fn load_persisted_settings(data_dir: &Path) -> PersistedSettings {
    let Ok(text) = std::fs::read_to_string(settings_path(data_dir)) else {
        return PersistedSettings::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save_persisted_settings(data_dir: &Path, settings: &PersistedSettings) -> std::io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    std::fs::write(
        settings_path(data_dir),
        serde_json::to_vec_pretty(settings)?,
    )
}

async fn record_stop(state: &Arc<AppState>, reason: Option<&str>) -> Response {
    memory::flush(&state.store, &state.models, &state.memories, llm_is_ready(state)).await;
    let _ = state
        .store
        .begin_idle_span(now_ms(), reason.unwrap_or("pause"));
    let (session_id, scheduler, consumer) = {
        let mut recording = state.recording.lock().await;
        let Some(session_id) = recording.active_session_id.take() else {
            return Response::success(serde_json::json!({"already_stopped": true}));
        };
        state.last_capture_ms.store(0, Ordering::SeqCst);
        state.recording_active.store(false, Ordering::SeqCst);
        (
            session_id,
            recording.scheduler.take(),
            recording.event_consumer.take(),
        )
    };
    if let Some(scheduler) = scheduler {
        scheduler.abort();
    }
    let capture_error = state.capture.stop_capture().await.err();
    if let Some(consumer) = consumer {
        let _ = tokio::time::timeout(Duration::from_secs(12), consumer).await;
    }
    let store_result = state.store.end_session_sync(&session_id, now_ms());
    match (capture_error, store_result) {
        (None, Ok(())) => Response::success(serde_json::json!({"session_id": session_id})),
        (Some(capture_error), Ok(())) => Response::failure(format!(
            "session closed, but capture helper did not stop cleanly: {capture_error}"
        )),
        (None, Err(store_error)) => Response::failure(store_error.to_string()),
        (Some(capture_error), Err(store_error)) => Response::failure(format!(
            "capture stop failed: {capture_error}; session close failed: {store_error}"
        )),
    }
}

async fn consume_capture_events(state: Arc<AppState>, session_id: String) {
    while let Some(event) = state.capture.next_event().await {
        match event {
            Ok(CaptureEvent::Ready { .. }) => {}
            Ok(CaptureEvent::Artifact {
                kind,
                path,
                content_type,
                started_at_ms,
                ended_at_ms,
                ..
            }) => {
                let result = import_artifact(
                    &state,
                    &session_id,
                    kind,
                    &path,
                    &content_type,
                    started_at_ms,
                    ended_at_ms,
                )
                .await;
                if let Err(error) = result {
                    eprintln!("capture artifact import failed: {error:#}");
                    let _ = tokio::fs::remove_file(&path).await;
                }
            }
            Ok(CaptureEvent::Warning { code, message }) => {
                eprintln!("capture warning [{code}]: {message}");
            }
            Ok(CaptureEvent::Failed { code, message }) => {
                eprintln!("capture failed [{code}]: {message}");
                finish_failed_recording(&state, &session_id).await;
                break;
            }
            Ok(CaptureEvent::Stopped) => break,
            Err(error) => {
                eprintln!("capture event stream failed: {error}");
                finish_failed_recording(&state, &session_id).await;
                break;
            }
        }
    }
}

async fn finish_failed_recording(state: &Arc<AppState>, session_id: &str) {
    let scheduler = {
        let mut recording = state.recording.lock().await;
        if recording.active_session_id.as_deref() != Some(session_id) {
            return;
        }
        recording.active_session_id = None;
        recording.captured_frame = false;
        recording.scheduler.take()
    };
    state.recording_active.store(false, Ordering::SeqCst);
    state.last_capture_ms.store(0, Ordering::SeqCst);
    if let Some(scheduler) = scheduler {
        scheduler.abort();
    }
    let _ = state.store.end_session_sync(session_id, now_ms());
}

async fn import_artifact(
    state: &Arc<AppState>,
    session_id: &str,
    kind: ArtifactKind,
    path: &Path,
    content_type: &str,
    started_at_ms: i64,
    ended_at_ms: i64,
) -> anyhow::Result<()> {
    let bytes = tokio::fs::read(path).await?;
    match kind {
        ArtifactKind::Screen => {
            let moment =
                state
                    .store
                    .insert_moment(session_id, started_at_ms, content_type, &bytes)?;
            {
                let mut recording = state.recording.lock().await;
                if recording.active_session_id.as_deref() == Some(session_id) {
                    recording.captured_frame = true;
                }
            }
            let job = state
                .models
                .submit(ModelInput::Ocr {
                    image_path: path.to_path_buf(),
                    prompt: None,
                })
                .await?;
            let model_state = Arc::clone(state);
            let path = path.to_path_buf();
            tokio::spawn(async move {
                let snapshot = model_state.models.wait(&job).await;
                if let Ok(snapshot) = snapshot
                    && let Some(ModelOutput::Ocr { text, regions }) = snapshot.output
                {
                    let layout_json = if regions.is_empty() {
                        None
                    } else {
                        serde_json::to_string(&regions).ok()
                    };
                    if let Ok(evidence_id) = model_state.store.insert_text_evidence(
                        &moment.session_id,
                        Some(&moment.id),
                        None,
                        "ocr",
                        &text,
                        moment.captured_at_ms,
                        None,
                        &snapshot.adapter,
                        layout_json.as_deref(),
                    ) {
                        submit_embedding(&model_state, evidence_id, text).await;
                    }
                }
                let _ = tokio::fs::remove_file(path).await;
            });
        }
        ArtifactKind::SystemAudio | ArtifactKind::Microphone => {
            let track = match kind {
                ArtifactKind::Microphone => afterray_protocol::AudioTrack::Microphone,
                ArtifactKind::SystemAudio | ArtifactKind::Screen | ArtifactKind::Accessibility => {
                    afterray_protocol::AudioTrack::System
                }
            };
            let segment = state.store.insert_audio_segment(
                session_id,
                track,
                started_at_ms,
                ended_at_ms,
                content_type,
                &bytes,
            )?;
            let job = state
                .models
                .submit(ModelInput::Asr {
                    audio_path: path.to_path_buf(),
                    language: None,
                })
                .await?;
            let model_state = Arc::clone(state);
            let path = path.to_path_buf();
            tokio::spawn(async move {
                match model_state.models.wait(&job).await {
                    Ok(snapshot) => match snapshot.output {
                        Some(ModelOutput::Asr { text, language }) => {
                            if text.trim().is_empty() {
                                eprintln!(
                                    "asr produced no visible text for {} ({})",
                                    segment.id,
                                    language.as_deref().unwrap_or("auto")
                                );
                            } else if let Ok(evidence_id) = model_state.store.insert_text_evidence(
                                &segment.session_id,
                                None,
                                Some(&segment.id),
                                "transcript",
                                &text,
                                segment.started_at_ms,
                                Some(segment.ended_at_ms),
                                &snapshot.adapter,
                                None,
                            ) {
                                submit_embedding(&model_state, evidence_id, text).await;
                            }
                        }
                        None => eprintln!(
                            "asr job {} ended {:?}{}",
                            snapshot.id,
                            snapshot.state,
                            snapshot
                                .last_error
                                .as_deref()
                                .map(|error| format!(": {error}"))
                                .unwrap_or_default()
                        ),
                        Some(_) => {
                            eprintln!("asr job {} returned a non-transcript output", snapshot.id)
                        }
                    },
                    Err(error) => eprintln!("asr job {job} did not finish: {error}"),
                }
                let _ = tokio::fs::remove_file(path).await;
            });
        }
        ArtifactKind::Accessibility => {
            let metadata =
                serde_json::from_slice::<AccessibilityMetadata>(&bytes).unwrap_or_default();
            if is_excluded_bundle(state, metadata.bundle_identifier.as_deref()) {
                if let Some(moment_id) = nearest_moment_id(&state.store, session_id, started_at_ms)
                {
                    let _ = state.store.delete_moment_and_artifacts(&moment_id);
                }
                tokio::fs::remove_file(path).await?;
                return Ok(());
            }
            let attached = attach_accessibility_artifact(
                &state.store,
                session_id,
                started_at_ms,
                content_type,
                &bytes,
            )?;
            if attached.is_some() {
                if let Some(moment_id) = nearest_moment_id(&state.store, session_id, started_at_ms)
                {
                    memory::observe_and_maybe_commit(
                        &state.store,
                        &state.models,
                        &state.memories,
                        started_at_ms,
                        &moment_id,
                        &bytes,
                        llm_is_ready(state),
                    )
                    .await;
                }
            } else {
                eprintln!(
                    "accessibility snapshot had no screen moment within the two-second alignment window"
                );
            }
            tokio::fs::remove_file(path).await?;
        }
    }
    Ok(())
}

#[derive(Default, serde::Deserialize)]
struct AccessibilityMetadata {
    application_name: Option<String>,
    bundle_identifier: Option<String>,
}

fn attach_accessibility_artifact(
    store: &Vault,
    session_id: &str,
    captured_at_ms: i64,
    content_type: &str,
    bytes: &[u8],
) -> Result<Option<String>, StoreError> {
    let metadata = serde_json::from_slice::<AccessibilityMetadata>(bytes).unwrap_or_default();
    store.attach_accessibility_snapshot(
        session_id,
        captured_at_ms,
        content_type,
        bytes,
        metadata.application_name.as_deref(),
        metadata.bundle_identifier.as_deref(),
    )
}

fn nearest_moment_id(store: &Vault, session_id: &str, captured_at_ms: i64) -> Option<String> {
    store
        .moments_sync(session_id)
        .ok()?
        .into_iter()
        .rev()
        .find(|moment| moment.captured_at_ms.abs_diff(captured_at_ms) <= 2_000)
        .map(|moment| moment.id)
}

async fn submit_embedding(state: &Arc<AppState>, evidence_id: String, text: String) {
    let Ok(job_id) = state.models.submit(ModelInput::Embedding { text }).await else {
        return;
    };
    let Ok(snapshot) = state.models.wait(&job_id).await else {
        return;
    };
    if snapshot.state == JobState::Done
        && let Some(ModelOutput::Embedding { vector }) = snapshot.output
    {
        let _ = state
            .store
            .insert_embedding(&evidence_id, &vector, &snapshot.adapter);
    }
}

pub(crate) async fn search_hits(
    store: &Vault,
    models: &ModelQueue,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>, StoreError> {
    let candidate_limit = limit.saturating_mul(4).clamp(limit, 400);
    let full_text = match store.search(query, candidate_limit) {
        Ok(hits) => hits,
        Err(error) => {
            eprintln!("full-text search unavailable; continuing with semantic search: {error}");
            Vec::new()
        }
    };
    let job_id = match models
        .submit(ModelInput::Embedding {
            text: query.to_owned(),
        })
        .await
    {
        Ok(job_id) => job_id,
        Err(error) => {
            eprintln!("semantic search unavailable; returning FTS results: {error}");
            return Ok(limit_hits(full_text, limit));
        }
    };
    let snapshot = match models.wait(&job_id).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            eprintln!(
                "semantic search job {job_id} could not be read; returning FTS results: {error}"
            );
            return Ok(limit_hits(full_text, limit));
        }
    };
    let ModelOutput::Embedding { vector } = (match snapshot.output {
        Some(output) if snapshot.state == JobState::Done => output,
        _ => {
            eprintln!(
                "semantic search job {job_id} did not complete; returning FTS results: {}",
                snapshot
                    .last_error
                    .unwrap_or_else(|| format!("state was {:?}", snapshot.state))
            );
            return Ok(limit_hits(full_text, limit));
        }
    }) else {
        eprintln!(
            "semantic search job {job_id} returned the wrong output type; returning FTS results"
        );
        return Ok(limit_hits(full_text, limit));
    };
    let semantic = match store.semantic_search(&vector, &snapshot.adapter, candidate_limit) {
        Ok(hits) => hits,
        Err(error) => {
            eprintln!("semantic search scoring failed; returning FTS results: {error}");
            return Ok(limit_hits(full_text, limit));
        }
    };
    Ok(fuse_search_results(full_text, semantic, limit))
}

fn limit_hits(mut hits: Vec<SearchHit>, limit: usize) -> Vec<SearchHit> {
    hits.truncate(limit);
    hits
}

async fn summarize(state: &Arc<AppState>, session_id: &str) -> Response {
    let text = match state.store.session_text(session_id) {
        Ok(text) if !text.is_empty() => text,
        Ok(_) => return Response::failure("the session has no OCR or transcript evidence yet"),
        Err(error) => return Response::failure(error.to_string()),
    };
    let prompt =
        format!("Summarize this local computer activity with concrete evidence:\n\n{text}");
    let job_id = match state
        .models
        .submit(ModelInput::Llm {
            prompt,
            system: Some(
                "You are AfterRay. Be concise and never invent missing evidence.".to_owned(),
            ),
        })
        .await
    {
        Ok(id) => id,
        Err(error) => return Response::failure(error.to_string()),
    };
    match state.models.wait(&job_id).await {
        Ok(snapshot) if snapshot.state == JobState::Done => Response::success(snapshot),
        Ok(snapshot) => Response::failure(
            snapshot
                .last_error
                .unwrap_or_else(|| "summary job did not complete".to_owned()),
        ),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn model_library(state: &AppState) -> afterray_protocol::ModelLibrary {
    let mut library = library();
    library.download = state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    library
}

async fn download_models(state: &Arc<AppState>, pack_id: Option<&str>) -> Response {
    let packs = match specs_for_download(pack_id) {
        Ok(packs) => packs,
        Err(error) => return Response::failure(error),
    };
    if packs.is_empty() {
        return Response::success(model_library(state));
    }
    let result = download_packs(&packs, |spec, progress| {
        let snapshot = ModelDownloadProgress {
            pack_id: spec.id.clone(),
            bytes: progress.bytes,
            expected_bytes: progress.expected_bytes,
            completed_files: u64::try_from(progress.completed_files).unwrap_or(0),
            total_files: u64::try_from(progress.total_files).unwrap_or(0),
        };
        if let Some(percent) = progress.percent() {
            eprintln!("Downloading {} · {percent}%", spec.name);
        } else {
            eprintln!(
                "Downloading {} ({}/{} files)",
                spec.name, progress.completed_files, progress.total_files
            );
        }
        *state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(snapshot);
    })
    .await;
    *state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    match result {
        Ok(()) => Response::success(model_library(state)),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn spawn_gop_packer(state: Arc<AppState>) {
    if !state.packer.config.archive {
        eprintln!("gop packer: AFTERRAY_GOP_ARCHIVE=0 (idle, cold stills stay JPEG)");
        return;
    }
    eprintln!(
        "gop packer: enabled keyint={} cold_gop_only require_ac={}",
        state.packer.config.policy.keyint, state.packer.config.require_ac
    );
    let shutdown = state.shutdown.subscribe();
    if let Err(error) = std::thread::Builder::new()
        .name("gop-packer".into())
        .spawn(move || {
            apply_background_qos();
            eprintln!("gop packer: background thread started");
            std::thread::sleep(Duration::from_secs(15));
            loop {
                if *shutdown.borrow() {
                    break;
                }
                if state.capture_busy.load(Ordering::SeqCst)
                    || state.packer.encode_busy()
                    || state.models.ocr_in_flight()
                    || gop_packer::should_yield_to_capture(
                        false,
                        state.recording_active.load(Ordering::SeqCst),
                        state.last_capture_ms.load(Ordering::SeqCst),
                        now_ms(),
                        i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000),
                    )
                {
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                match state.packer.pack_one(&state.store, now_ms()) {
                    Ok(Some(segment_id)) => {
                        eprintln!("gop packer: committed {segment_id}");
                    }
                    Ok(None) => {}
                    Err(error) => eprintln!("gop packer: {error:#}"),
                }
                std::thread::sleep(Duration::from_secs(5));
            }
        })
    {
        eprintln!("gop packer: failed to spawn background thread: {error}");
    }
}

fn read_still_artifact(state: &AppState, artifact_id: &str) -> Result<ArtifactPayload, StoreError> {
    let payload = state.store.read_artifact(artifact_id)?;
    if payload.content_type.starts_with("video/") {
        return Err(StoreError::GopNotFound(
            "use read_gop_segment for IVF artifacts".into(),
        ));
    }
    let _ = CONTENT_TYPE_IVF_AV01;
    Ok(payload)
}

/// Smallest pixels available for a moment, for the search filmstrip.
///
/// Tries, in order: a cached thumbnail; building one from the hot still; the
/// cold GOP frame itself. That last case exists only for moments packed before
/// thumbnails shipped — this process can encode AV1 but not decode it, so the
/// client has to do the downscaling. The packer thumbnails everything it packs,
/// so the fallback drains as the legacy corpus ages out.
fn read_moment_thumbnail(
    store: &Vault,
    moment_id: &str,
    max_edge: Option<u32>,
) -> Result<ArtifactPayload, StoreError> {
    if let Some(artifact_id) = store.thumbnail_artifact_id(moment_id)? {
        return store.read_artifact(&artifact_id);
    }
    let moment = store
        .moment_by_id(moment_id)?
        .ok_or_else(|| StoreError::MomentNotFound(moment_id.to_owned()))?;

    if let Some(image_artifact_id) = moment.image_artifact_id.as_deref() {
        let still = store.read_artifact(image_artifact_id)?;
        let max_edge = max_edge.unwrap_or(DEFAULT_THUMBNAIL_MAX_EDGE);
        match still_thumbnail(&still.bytes, max_edge) {
            Ok(bytes) => {
                let artifact_id = store.set_thumbnail(moment_id, &bytes)?;
                return store.read_artifact(&artifact_id);
            }
            Err(error) => {
                // A still we cannot re-encode is still a still. Hand over the
                // original rather than leaving a hole in the filmstrip.
                eprintln!("thumbnail encode failed for moment {moment_id}: {error}");
                return Ok(still);
            }
        }
    }

    if let Some(gop) = moment.gop {
        return gop_packer::read_gop_frame(store, &gop.segment_id, gop.index, GopReadMode::Exact);
    }
    Err(StoreError::ArtifactNotFound(format!(
        "moment {moment_id} has no still, thumbnail, or packed frame"
    )))
}

fn pack_status(state: &AppState) -> Response {
    match state.store.pack_status_counts() {
        Ok((running, done, failed, ready)) => Response::success(PackStatus {
            archive_enabled: state.packer.config.archive,
            keep_stills: false,
            keyint: state.packer.config.policy.keyint,
            encoder: "rav1e".to_owned(),
            hot_window_seconds: u64::try_from(state.packer.config.policy.hot_window_ms / 1000)
                .unwrap_or(7200),
            running_jobs: running,
            done_jobs: done,
            failed_jobs: failed,
            ready_segments: ready,
        }),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn into_response<T: serde::Serialize, E: std::fmt::Display>(result: Result<T, E>) -> Response {
    match result {
        Ok(data) => Response::success(data),
        Err(error) => Response::failure(error.to_string()),
    }
}

fn now_ms() -> i64 {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_models::{ModelAdapter, ModelCapability, ProcessAdapter, ProcessAdapterConfig};
    use tokio::io::AsyncReadExt;

    #[test]
    fn stale_capture_cleanup_only_removes_files() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("screen.jpg"), b"frame").unwrap();
        std::fs::write(directory.path().join("microphone.m4a"), b"audio").unwrap();
        std::fs::create_dir(directory.path().join("unexpected-directory")).unwrap();

        assert_eq!(clear_stale_capture_files(directory.path()).unwrap(), 2);
        assert!(directory.path().join("unexpected-directory").is_dir());
        assert_eq!(clear_stale_capture_files(directory.path()).unwrap(), 0);
    }

    fn test_vault() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_unstarred_moments: 100,
            },
            [9_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    /// A committed 96x64 JPEG so thumbnail tests never depend on ffmpeg.
    fn fixture_jpeg() -> Vec<u8> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../afterray-codec/fixtures/still-96x64.jpg");
        std::fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()))
    }

    #[test]
    fn thumbnail_is_built_from_a_hot_still_then_cached() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", &fixture_jpeg())
            .unwrap();
        assert!(vault.thumbnail_artifact_id(&moment.id).unwrap().is_none());

        let first = read_moment_thumbnail(&vault, &moment.id, Some(48)).unwrap();
        assert_eq!(first.content_type, "image/jpeg");
        assert!(first.bytes.starts_with(&[0xFF, 0xD8, 0xFF]));

        // The build is cached, so a second read returns the same artifact
        // instead of decoding the full still again.
        let cached_id = vault
            .thumbnail_artifact_id(&moment.id)
            .unwrap()
            .expect("thumbnail should have been cached");
        assert_eq!(cached_id, first.id);
        let second = read_moment_thumbnail(&vault, &moment.id, Some(48)).unwrap();
        assert_eq!(second.id, first.id);
        assert_eq!(second.bytes, first.bytes);
    }

    #[test]
    fn thumbnail_of_an_unknown_moment_fails_cleanly() {
        let (_directory, vault) = test_vault();
        let error = read_moment_thumbnail(&vault, "nope", None).unwrap_err();
        assert!(
            matches!(error, StoreError::MomentNotFound(_)),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn packing_thumbnails_every_still_before_dropping_it() {
        let jpegs = load_e2e_jpegs();
        if jpegs.len() < 2 {
            eprintln!("skip: no JPEG fixtures and ffmpeg unavailable");
            return;
        }
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let mut ids = Vec::new();
        for (index, jpeg) in jpegs.iter().enumerate() {
            let captured = 1_000 + i64::try_from(index).unwrap() * 10_000;
            let moment = vault
                .insert_moment(&session.id, captured, "image/jpeg", jpeg)
                .unwrap();
            ids.push(moment.id);
        }
        let packer = gop_packer::GopPacker::new(gop_packer::GopPackerConfig {
            archive: true,
            require_ac: false,
            policy: afterray_store::PackPolicy {
                hot_window_ms: 0,
                hot_min_stills: 0,
                ocr_grace_ms: 0,
                keyint: 6,
            },
        });
        packer
            .pack_one(&vault, 10_000_000)
            .unwrap()
            .expect("packer should emit a GOP");

        // Once packed the JPEG is gone, so the thumbnail is the only cheap way
        // back to these pixels. Every packed moment must already have one.
        for id in &ids {
            let moment = vault.moment_by_id(id).unwrap().unwrap();
            if moment.gop.is_none() {
                continue;
            }
            assert!(
                moment.image_artifact_id.is_none(),
                "packed moment kept its still"
            );
            let thumbnail = read_moment_thumbnail(&vault, id, None).unwrap();
            assert_eq!(thumbnail.content_type, "image/jpeg");
            assert!(thumbnail.bytes.starts_with(&[0xFF, 0xD8, 0xFF]));
        }
    }

    fn queue(adapters: Vec<Arc<dyn ModelAdapter>>) -> ModelQueue {
        ModelQueue::new(adapters, QueueConfig::default()).unwrap()
    }

    #[tokio::test]
    async fn search_returns_fts_when_embedding_adapter_is_unavailable() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "needle in local memory",
                1,
                None,
                "ocr-model",
                None,
            )
            .unwrap();

        let hits = search_hits(&vault, &queue(Vec::new()), "needle", 10)
            .await
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].text, "needle in local memory");
    }

    #[tokio::test]
    async fn search_embeds_query_and_fuses_semantic_results() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let exact_id = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "needle exact words",
                1,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        let semantic_id = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "conceptual local context",
                2,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        vault
            .insert_embedding(&exact_id, &[0.0, 1.0], "test-embedding")
            .unwrap();
        vault
            .insert_embedding(&semantic_id, &[1.0, 0.0], "test-embedding")
            .unwrap();

        let script = r#"
import json, sys
json.load(sys.stdin)
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "embedding", "vector": [1.0, 0.0]},
  "retryable": False
}))
"#;
        let mut config = ProcessAdapterConfig::new(
            "test-embedding",
            ModelCapability::Embedding,
            "/usr/bin/python3",
        );
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let models = queue(vec![Arc::new(ProcessAdapter::new(config))]);
        let hits = search_hits(&vault, &models, "needle", 10).await.unwrap();

        assert_eq!(hits.len(), 2);
        assert!(hits.iter().any(|hit| hit.text == "needle exact words"));
        assert!(
            hits.iter()
                .any(|hit| hit.text == "conceptual local context")
        );
    }

    #[tokio::test]
    async fn read_artifact_writes_json_header_then_raw_bytes() {
        let payload = ArtifactPayload {
            id: "a1".to_owned(),
            content_type: "image/jpeg".to_owned(),
            bytes: b"raw-jpeg".to_vec(),
        };
        let (server, client) = UnixStream::pair().unwrap();
        let (_ignored, mut write) = server.into_split();
        write_artifact_response(&mut write, Ok(payload))
            .await
            .unwrap();
        drop(write);

        let (read, _unused) = client.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: Response = serde_json::from_str(&line).unwrap();
        assert!(response.ok);
        let meta: afterray_protocol::ArtifactMeta =
            serde_json::from_value(response.data.unwrap()).unwrap();
        assert_eq!(meta.id, "a1");
        assert_eq!(meta.content_type, "image/jpeg");
        assert_eq!(meta.byte_length, 8);
        let mut body = vec![0_u8; 8];
        reader.read_exact(&mut body).await.unwrap();
        assert_eq!(body, b"raw-jpeg");
    }

    #[tokio::test]
    async fn missing_artifact_writes_json_error_without_body() {
        let (server, client) = UnixStream::pair().unwrap();
        let (_ignored, mut write) = server.into_split();
        write_artifact_response(
            &mut write,
            Err(StoreError::ArtifactNotFound("missing".into())),
        )
        .await
        .unwrap();
        drop(write);

        let (read, _unused) = client.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: Response = serde_json::from_str(&line).unwrap();
        assert!(!response.ok);
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).await.unwrap();
        assert!(rest.is_empty());
    }

    fn load_e2e_jpegs() -> Vec<Vec<u8>> {
        let dir = std::path::Path::new("/tmp/afterray-gop-sim/frames/Lody");
        if dir.is_dir() {
            let mut files: Vec<_> = std::fs::read_dir(dir)
                .unwrap()
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "jpg"))
                .collect();
            files.sort();
            let take = if std::env::var("AFTERRAY_GOP_E2E_FULL").is_ok() {
                12
            } else {
                4
            };
            return files
                .into_iter()
                .take(take)
                .map(|path| std::fs::read(path).unwrap())
                .collect();
        }
        let scratch = tempfile::tempdir().unwrap();
        let mut frames = Vec::new();
        for index in 0..4 {
            let path = scratch.path().join(format!("{index}.jpg"));
            let status = std::process::Command::new("ffmpeg")
                .args([
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                    &format!(
                        "color=c=red:s=64x64:d=1,drawbox=c=white:t=fill:enable='gte(t\\,{index})'"
                    ),
                    "-frames:v",
                    "1",
                    "-q:v",
                    "2",
                ])
                .arg(&path)
                .status();
            if !status.map(|code| code.success()).unwrap_or(false) {
                return Vec::new();
            }
            frames.push(std::fs::read(path).unwrap());
        }
        frames
    }

    #[test]
    fn packer_encodes_closed_gop_and_serves_poster() {
        let jpegs = load_e2e_jpegs();
        if jpegs.len() < 2 {
            eprintln!("skip packer e2e: no JPEG fixtures and ffmpeg unavailable");
            return;
        }
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let mut ids = Vec::new();
        for (index, jpeg) in jpegs.iter().enumerate() {
            let captured = 1_000 + i64::try_from(index).unwrap() * 10_000;
            let moment = vault
                .insert_moment(&session.id, captured, "image/jpeg", jpeg)
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    "screen",
                    captured,
                    None,
                    "ocr",
                None,
            )
                .unwrap();
            ids.push(moment.id);
        }
        let jpeg_bytes: usize = jpegs.iter().map(Vec::len).sum();
        let packer = gop_packer::GopPacker::new(gop_packer::GopPackerConfig {
            archive: true,
            require_ac: false,
            policy: afterray_store::PackPolicy {
                hot_window_ms: 0,
                hot_min_stills: 0,
                ocr_grace_ms: 0,
                keyint: if jpegs.len() >= 12 { 12 } else { 6 },
            },
        });
        let segment = packer
            .pack_one(&vault, 10_000_000)
            .unwrap()
            .expect("packer should emit a GOP");
        let view = vault.gop_segment_view(&segment).unwrap();
        assert_eq!(view.codec, "av01");
        assert_eq!(view.encoder, "rav1e");
        assert!(view.frames.len() >= 2);
        let payload = vault.read_gop_artifact(&segment).unwrap();
        assert!(payload.bytes.starts_with(b"DKIF"));
        let parsed = afterray_codec::parse_ivf(&payload.bytes).unwrap();
        assert_eq!(parsed.frames.len(), view.frames.len());
        let _ = std::fs::write("/tmp/afterray-gop-e2e.ivf", &payload.bytes);
        let ratio = payload.bytes.len() as f64 / jpeg_bytes as f64;
        eprintln!(
            "gop e2e: {} frames jpeg={} ivf={} ratio={:.4} ({:.1}x)",
            view.frames.len(),
            jpeg_bytes,
            payload.bytes.len(),
            ratio,
            1.0 / ratio
        );
        assert!(
            ratio < 0.20,
            "GOP should beat 5x vs JPEG, got {:.1}%",
            ratio * 100.0
        );
        let packed = vault.moments_sync(&session.id).unwrap();
        for moment in &packed {
            if ids.contains(&moment.id) {
                assert!(moment.gop.is_some(), "cold moment should play from GOP");
                assert!(
                    moment.image_artifact_id.is_none(),
                    "cold GOP must drop the JPEG still"
                );
            }
        }
        let poster =
            gop_packer::read_gop_frame(&vault, &segment, 0, afterray_protocol::GopReadMode::Poster)
                .unwrap();
        let poster_ivf = afterray_codec::parse_ivf(&poster.bytes).unwrap();
        assert_eq!(poster_ivf.frames.len(), 1);
    }

    fn tiny_jpeg() -> Option<Vec<u8>> {
        let scratch = tempfile::tempdir().ok()?;
        let path = scratch.path().join("one.jpg");
        let status = std::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=blue:s=64x64:d=1",
                "-frames:v",
                "1",
                "-q:v",
                "2",
            ])
            .arg(&path)
            .status()
            .ok()?;
        if !status.success() {
            return None;
        }
        std::fs::read(path).ok()
    }

    #[test]
    fn packer_encodes_a_single_cold_still() {
        let Some(jpeg) = tiny_jpeg() else {
            eprintln!("skip single-frame pack: ffmpeg unavailable");
            return;
        };
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", &jpeg)
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                Some(&moment.id),
                None,
                "ocr",
                "screen",
                1_000,
                None,
                "ocr",
                None,
            )
            .unwrap();
        let packer = gop_packer::GopPacker::new(gop_packer::GopPackerConfig {
            archive: true,
            require_ac: false,
            policy: afterray_store::PackPolicy {
                hot_window_ms: 0,
                hot_min_stills: 0,
                ocr_grace_ms: 0,
                keyint: 12,
            },
        });
        let segment = packer
            .pack_one(&vault, 10_000_000)
            .unwrap()
            .expect("n==1 cold tail should encode as a still GOP");
        let view = vault.gop_segment_view(&segment).unwrap();
        assert_eq!(view.frames.len(), 1);
        let packed = vault.moments_sync(&session.id).unwrap();
        assert!(packed[0].gop.is_some());
        assert!(packed[0].image_artifact_id.is_none());
    }

    fn live_socket() -> Option<std::path::PathBuf> {
        if let Some(path) = std::env::var_os("AFTERRAY_SOCKET") {
            return Some(std::path::PathBuf::from(path));
        }
        let dev = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.afterray-dev/afterray.sock");
        dev.exists().then_some(dev)
    }

    fn daemon_rpc(
        socket: &std::path::Path,
        request: afterray_protocol::Request,
    ) -> afterray_protocol::Response {
        use std::io::{BufRead as _, BufReader, Write as _};
        let mut stream = std::os::unix::net::UnixStream::connect(socket)
            .unwrap_or_else(|error| panic!("connect {}: {error}", socket.display()));
        let mut bytes = serde_json::to_vec(&request).unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    fn daemon_read_artifact(socket: &std::path::Path, artifact_id: &str) -> Vec<u8> {
        use std::io::{BufRead as _, Read as _, Write as _};
        let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
        let mut bytes = serde_json::to_vec(&afterray_protocol::Request::ReadArtifact {
            artifact_id: artifact_id.to_owned(),
        })
        .unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).unwrap();
        let mut reader = std::io::BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let header: afterray_protocol::Response = serde_json::from_str(&line).unwrap();
        assert!(header.ok, "read_artifact {artifact_id}: {:?}", header.error);
        let meta: afterray_protocol::ArtifactMeta =
            serde_json::from_value(header.data.unwrap()).unwrap();
        assert!(meta.byte_length > 0 && meta.byte_length <= 8 * 1024 * 1024);
        let mut body = vec![0_u8; usize::try_from(meta.byte_length).unwrap()];
        reader.read_exact(&mut body).unwrap();
        assert!(
            body.starts_with(&[0xFF, 0xD8, 0xFF]),
            "live still {artifact_id} is not JPEG"
        );
        body
    }

    fn is_loginwindow(moment: &afterray_protocol::Moment) -> bool {
        moment
            .application_name
            .as_deref()
            .is_some_and(|name| name.eq_ignore_ascii_case("loginwindow"))
            || moment
                .bundle_identifier
                .as_deref()
                .is_some_and(|bundle| bundle.to_ascii_lowercase().contains("loginwindow"))
    }

    #[test]
    fn verify_production_stills_end_to_end() {
        if std::env::var_os("AFTERRAY_GOP_VERIFY").is_none() {
            eprintln!("skip: set AFTERRAY_GOP_VERIFY=1 to pull live stills");
            return;
        }
        let Some(socket) = live_socket() else {
            eprintln!("skip: live afterrayd socket not found");
            return;
        };
        let max_segments: usize = std::env::var("AFTERRAY_GOP_VERIFY_MAX")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(6);
        let status = daemon_rpc(&socket, afterray_protocol::Request::Status);
        assert!(status.ok, "live daemon status failed: {:?}", status.error);
        let status: afterray_protocol::Status =
            serde_json::from_value(status.data.unwrap()).unwrap();
        assert_eq!(status.protocol_version, afterray_protocol::PROTOCOL_VERSION);
        assert_eq!(status.schema_version, afterray_store::SCHEMA_VERSION);

        let pack = daemon_rpc(&socket, afterray_protocol::Request::PackStatus);
        let pack: afterray_protocol::PackStatus =
            serde_json::from_value(pack.data.unwrap()).unwrap();
        assert!(!pack.keep_stills, "Dual keep_stills must stay off");
        assert_eq!(pack.keyint, 30);
        assert_eq!(pack.hot_window_seconds, 7200);

        let timeline = daemon_rpc(&socket, afterray_protocol::Request::TimelineList);
        assert!(timeline.ok, "timeline_list failed: {:?}", timeline.error);
        let moments: Vec<afterray_protocol::Moment> =
            serde_json::from_value(timeline.data.unwrap()).unwrap();
        assert!(!moments.is_empty(), "live vault has no moments");

        let now = now_ms();
        let cutoff = now.saturating_sub(7_200_000);
        let mut hot_jpeg = 0_usize;
        let mut cold_jpeg = 0_usize;
        let mut already_gop = 0_usize;
        let mut favorites = 0_usize;
        let mut loginwindow = 0_usize;
        let mut missing_still = 0_usize;
        for moment in &moments {
            if is_loginwindow(moment) {
                loginwindow += 1;
                assert!(
                    moment.gop.is_none(),
                    "live loginwindow {} is packed",
                    moment.id
                );
            }
            if moment.is_favorite {
                favorites += 1;
            }
            if moment.gop.is_some() {
                already_gop += 1;
                if !moment.is_favorite {
                    assert!(
                        moment.image_artifact_id.is_none(),
                        "live Dual leftover {}",
                        moment.id
                    );
                }
            } else if moment.image_artifact_id.is_some() {
                if moment.captured_at_ms > cutoff {
                    hot_jpeg += 1;
                } else {
                    cold_jpeg += 1;
                }
            } else {
                missing_still += 1;
            }
        }
        eprintln!(
            "live vault: moments={} hot_jpeg={} cold_jpeg={} gop={} favorites={} loginwindow={} missing={}",
            moments.len(),
            hot_jpeg,
            cold_jpeg,
            already_gop,
            favorites,
            loginwindow,
            missing_still
        );
        assert_eq!(missing_still, 0, "live unpacked moment has no JPEG");
        assert!(
            cold_jpeg > 0,
            "need cold production JPEGs outside the 2h window"
        );

        let mut dense: Vec<&afterray_protocol::Moment> = Vec::new();
        for moment in &moments {
            if moment.gop.is_some()
                || moment.image_artifact_id.is_none()
                || is_loginwindow(moment)
                || moment.captured_at_ms > cutoff
            {
                continue;
            }
            if let Some(previous) = dense.last()
                && moment
                    .captured_at_ms
                    .saturating_sub(previous.captured_at_ms)
                    > 30_000
            {
                if dense.len() >= 12 {
                    break;
                }
                dense.clear();
            }
            dense.push(moment);
            if dense.len() >= max_segments.saturating_mul(12) {
                break;
            }
        }
        assert!(
            dense.len() >= 2,
            "could not find a dense cold run in production timeline"
        );
        eprintln!(
            "sampling {} cold stills from {} → {}",
            dense.len(),
            dense
                .first()
                .unwrap()
                .application_name
                .as_deref()
                .unwrap_or("?"),
            dense
                .last()
                .unwrap()
                .application_name
                .as_deref()
                .unwrap_or("?")
        );

        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let mut want = 0_usize;
        for moment in &dense {
            let jpeg = daemon_read_artifact(
                socket.as_path(),
                moment.image_artifact_id.as_deref().unwrap(),
            );
            want += jpeg.len();
            let inserted = vault
                .insert_moment(&session.id, moment.captured_at_ms, "image/jpeg", &jpeg)
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&inserted.id),
                    None,
                    "ocr",
                    "prod",
                    moment.captured_at_ms,
                    None,
                    "ocr",
                None,
            )
                .unwrap();
        }
        eprintln!("imported {want} JPEG bytes into an isolated vault");

        let policy = afterray_store::PackPolicy {
            hot_window_ms: 0,
            hot_min_stills: 0,
            ocr_grace_ms: 0,
            keyint: 12,
        };
        let packer = gop_packer::GopPacker::new(gop_packer::GopPackerConfig {
            archive: true,
            require_ac: false,
            policy: policy.clone(),
        });
        let mut packed = 0_usize;
        let mut ivf_bytes = 0_usize;
        let mut jpeg_bytes = 0_usize;
        let mut multi_frame = None;
        for _ in 0..max_segments {
            let candidates = vault.list_pack_candidates(now, &policy).unwrap();
            let Some(run) = afterray_store::fold_pack_runs(&candidates, 12)
                .into_iter()
                .next()
            else {
                break;
            };
            for frame in &run {
                jpeg_bytes += vault
                    .read_artifact(&frame.image_artifact_id)
                    .unwrap()
                    .bytes
                    .len();
            }
            let segment = packer
                .pack_one(&vault, now)
                .unwrap_or_else(|error| panic!("pack failed: {error:#}"))
                .expect("production stills should pack");
            let view = vault.gop_segment_view(&segment).unwrap();
            assert_eq!(view.codec, "av01");
            assert_eq!(view.encoder, "rav1e");
            assert_eq!(view.frames.len(), run.len());
            let payload = vault.read_gop_artifact(&segment).unwrap();
            assert!(payload.bytes.starts_with(b"DKIF"));
            assert_eq!(
                afterray_codec::parse_ivf(&payload.bytes)
                    .unwrap()
                    .frames
                    .len(),
                view.frames.len()
            );
            ivf_bytes += payload.bytes.len();
            let poster = gop_packer::read_gop_frame(
                &vault,
                &segment,
                0,
                afterray_protocol::GopReadMode::Poster,
            )
            .unwrap();
            assert_eq!(
                afterray_codec::parse_ivf(&poster.bytes)
                    .unwrap()
                    .frames
                    .len(),
                1
            );
            let last = u16::try_from(view.frames.len() - 1).unwrap();
            let exact = gop_packer::read_gop_frame(
                &vault,
                &segment,
                last,
                afterray_protocol::GopReadMode::Exact,
            )
            .unwrap();
            assert_eq!(
                afterray_codec::parse_ivf(&exact.bytes)
                    .unwrap()
                    .frames
                    .len(),
                view.frames.len()
            );
            for moment in vault.moments_sync(&session.id).unwrap() {
                if moment
                    .gop
                    .as_ref()
                    .is_some_and(|gop| gop.segment_id == segment)
                {
                    assert!(moment.image_artifact_id.is_none(), "Dual JPEG leftover");
                }
            }
            if view.frames.len() > 1 {
                multi_frame = Some((segment.clone(), payload.bytes.clone()));
            }
            packed += 1;
        }
        assert!(packed > 0, "no GOP packed from production stills");
        let ratio = ivf_bytes as f64 / jpeg_bytes.max(1) as f64;
        eprintln!(
            "packed {packed} GOP(s) jpeg={jpeg_bytes} ivf={ivf_bytes} ratio={ratio:.4} ({:.1}x)",
            1.0 / ratio
        );
        assert!(
            ratio < 0.20,
            "GOP should beat 5x vs JPEG, got {:.1}%",
            ratio * 100.0
        );
        assert_eq!(vault.cleanup_unreferenced_gop_artifacts().unwrap(), 0);

        let Some((segment, ivf)) = multi_frame else {
            panic!("expected at least one multi-frame production GOP");
        };
        let ivf_path = std::path::Path::new("/tmp/afterray-gop-verify-prod.ivf");
        std::fs::write(ivf_path, &ivf).unwrap();
        let status = std::process::Command::new("swift")
            .arg("scripts/prove-av1-decode.swift")
            .arg(ivf_path)
            .current_dir(env!("CARGO_MANIFEST_DIR").to_owned() + "/../..")
            .status()
            .expect("run prove-av1-decode.swift");
        assert!(
            status.success(),
            "VideoToolbox failed to decode production GOP {segment}"
        );
    }
}
