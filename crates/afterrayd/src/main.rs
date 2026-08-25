mod agent;
mod ask;
mod chat;
mod compute;
mod gop_packer;
mod memory;
mod ocr_crop;
mod stream;
mod tools;
mod turn_row;

use afterray_codec::{CONTENT_TYPE_IVF_AV01, DEFAULT_THUMBNAIL_MAX_EDGE, still_thumbnail};
use afterray_harness::ContextBudget;
use afterray_models::{
    Cancellation, DownloadError, JobState, LlmRouterAdapter, LlmRuntimeConfig, LlmTokenSink,
    ModelAdapter, ModelCapability, ModelInput, ModelOutput, ModelQueue, OcrRegion,
    PersistentMlxAdapter, PersistentMlxConfig, ProcessAdapter, ProcessAdapterConfig,
    QWEN3_ALIGNER_PACK_ID, QWEN35_4B_MLX_PACK_ID, QWEN35_4B_MLX_REVISION, QWEN35_9B_MLX_PACK_ID,
    QWEN35_9B_MLX_REVISION, QueueConfig, TranscriptCue, download_packs_with_cancellation,
    huggingface_mirror_to_persist, library, model_directory, probe_llm, qwen35_9b_mlx_manifest,
    qwen35_mlx_manifest, reclaim_abandoned_downloads, remove_pack, spec_by_id, specs_for_download,
};
use afterray_platform_macos::{
    ArtifactKind, CaptureConfig, CaptureError, CaptureEvent, InputEventRecord, MacOsCaptureBackend,
    apply_background_qos, parent_app_anchor, peer_is_afterray_app,
};
use afterray_protocol::{
    AppSettings, ArtifactPayload, CLI_EVIDENCE_WINDOW_MS, DEFAULT_STORAGE_LIMIT_BYTES, GopReadMode,
    HistoryScope, LlmProvider, ModelDownloadProgress, PROTOCOL_VERSION, PackStatus, RecordingState,
    Request, Response, SearchHit, Status, authorize_cli_request, local_calendar_day_bounds_ms,
    redact_cli_response_data,
};
use afterray_store::{
    AsrHealth, InputEventRow, LLM_API_KEY_SECRET, MacOsKeychainProvider, SlotSummaryState,
    StoreError, Vault, VaultConfig,
};
use anyhow::Context;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Mutex,
    task::JoinHandle,
};
use uuid::Uuid;

/// Binds the control socket without ever clobbering a path we do not own.
///
/// Everything reachable over this socket is plaintext history, so the socket
/// is the vault's front door. The old code ran an unconditional
/// `remove_file` on whatever sat at the path and bound with the process
/// umask, which in a shared directory is a socket-hijacking primitive and in
/// any directory left the socket group- and world-connectable.
///
/// Returns the listener and the uid that owns it, which is this process's own
/// effective uid — read back from the filesystem so we stay clear of an
/// `unsafe` `geteuid` call in a crate that denies unsafe code.
fn bind_control_socket(socket: &Path) -> anyhow::Result<(UnixListener, u32)> {
    use std::os::unix::fs::{FileTypeExt as _, MetadataExt as _, PermissionsExt as _};

    let parent = socket
        .parent()
        .context("daemon socket path has no parent directory")?;
    std::fs::create_dir_all(parent).context("create daemon socket directory")?;
    let metadata = std::fs::metadata(parent).context("inspect daemon socket directory")?;
    let mode = metadata.permissions().mode() & 0o777;
    // Only tighten a directory that other users can enter or write. Forcing
    // `0700` unconditionally would silently re-permission whatever directory
    // an `AFTERRAY_SOCKET` override happened to name.
    if mode & 0o077 != 0 {
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(mode & 0o700))
            .with_context(|| {
                format!(
                    "{} can be reached by other users and could not be restricted",
                    parent.display()
                )
            })?;
    }
    let our_uid = metadata.uid();

    // `symlink_metadata` does not follow a symlink, so a link planted at the
    // socket path is seen for what it is and refused instead of letting the
    // unlink below land on its target.
    match std::fs::symlink_metadata(socket) {
        Ok(metadata) => {
            if !metadata.file_type().is_socket() {
                anyhow::bail!(
                    "{} exists and is not a socket; refusing to replace it",
                    socket.display()
                );
            }
            if metadata.uid() != our_uid {
                anyhow::bail!(
                    "{} is owned by uid {}; refusing to replace it",
                    socket.display(),
                    metadata.uid()
                );
            }
            if std::os::unix::net::UnixStream::connect(socket).is_ok() {
                anyhow::bail!(
                    "another afterrayd is already listening on {}",
                    socket.display()
                );
            }
            std::fs::remove_file(socket).context("remove stale daemon socket")?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("inspect daemon socket path"),
    }

    let listener = UnixListener::bind(socket).context("bind daemon socket")?;
    // The window between `bind` and this `chmod` is covered by the `0700`
    // directory above: no other user can reach the path to connect through it.
    // macOS enforces socket permissions on connect(2), so this is what keeps
    // the door shut afterwards.
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))
        .context("restrict daemon socket")?;
    Ok((listener, our_uid))
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

/// UI traffic (socket accepts, chat streams, artifact scrubbing) must never
/// share a tiny worker pool with capture import, day-summary builds, or other
/// long CPU work. Default `#[tokio::main]` sizes workers to one per core; we
/// oversubscribe so a few blocked tasks cannot starve the accept loop.
fn main() -> anyhow::Result<()> {
    let workers = std::thread::available_parallelism()
        .map(|n| n.get().saturating_mul(2).max(8))
        .unwrap_or(8);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        // Default is 512; keep it high so spawn_blocking UI reads never queue
        // behind capture encrypt / T2 / GOP-adjacent store work.
        .max_blocking_threads(512)
        .thread_name("afterrayd-worker")
        .enable_all()
        .build()
        .context("build tokio runtime")?;
    let result = runtime.block_on(async_main());
    // `spawn_blocking` work cannot be aborted once it has started. Do not let a
    // disposable maintenance read keep the process alive after the bounded
    // shutdown path has completed.
    runtime.shutdown_timeout(Duration::from_secs(1));
    result
}

async fn async_main() -> anyhow::Result<()> {
    let socket =
        afterray_protocol::socket::default_socket_path().context("resolve daemon socket path")?;
    let (listener, owner_uid) = bind_control_socket(&socket)?;

    let mut vault_config = VaultConfig::default();
    if let Some(path) = std::env::var_os("AFTERRAY_DATA_DIR") {
        vault_config.data_dir = PathBuf::from(path);
    }
    let staging_dir = vault_config.data_dir.join("capture-staging");
    let removed_staging_files = clear_stale_capture_files(&staging_dir)?;
    if removed_staging_files > 0 {
        eprintln!("removed {removed_staging_files} stale capture staging file(s)");
    }
    let persisted = migrate_api_key_to_keychain(
        &vault_config.data_dir,
        load_persisted_settings(&vault_config.data_dir),
    );
    vault_config.max_storage_bytes = persisted.storage_limit_bytes;
    afterray_models::set_huggingface_endpoint(Some(persisted.model_download_endpoint.clone()));
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
    let mlx_worker_path = resolve_helper_path(
        "AFTERRAY_MLX_WORKER",
        "afterray-mlx-vlm-worker",
        ".build/release/afterray-mlx-vlm-worker",
    );
    let mlx_asr_worker_path = resolve_helper_path(
        "AFTERRAY_MLX_ASR_WORKER",
        "asr/afterray-mlx-asr-worker",
        "apps/AfterRayMlxAsrWorker/.build/release/afterray-mlx-asr-worker",
    );
    let (adapters, llm_token_sink, mlx_adapters) = local_model_adapters(
        native_worker_path,
        worker_path,
        mlx_worker_path,
        mlx_asr_worker_path,
        Arc::clone(&llm_config),
    );
    let models = ModelQueue::new(
        adapters,
        QueueConfig {
            // AFTERRAY_GPU_LANE=0 restores the old free-for-all scheduling.
            gpu_lane: std::env::var("AFTERRAY_GPU_LANE").as_deref() != Ok("0"),
            ..QueueConfig::default()
        },
    )?;

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let packer = Arc::new(gop_packer::GopPacker::new(
        gop_packer::GopPackerConfig::from_env(),
    ));
    // AFTERRAY_GPU_PROBE=0 skips the machine-GPU check on summaries; without
    // a probe the gate would only ever answer "unavailable", which is a hold.
    let gpu_probe_enabled = std::env::var("AFTERRAY_GPU_PROBE").as_deref() != Ok("0");
    let compute = Arc::new(compute::ComputeGovernor::new(
        persisted.compute_mode,
        persisted.compute_paused_until_ms,
        compute::ComputeLimits {
            summaries_disabled_by_env: t2_sweep_period().is_zero(),
            archive_disabled_by_env: !packer.config.archive,
            gpu_probe_disabled_by_env: !gpu_probe_enabled,
        },
    ));
    // Persisted durations, so "summaries usually take about this long" is
    // answerable immediately after a restart — which is exactly when someone
    // who just updated the app may be wondering why their fans are up. Read
    // once here, never on the dashboard's polling path.
    if let Some(until) = compute.paused_until_ms(now_ms()) {
        eprintln!(
            "compute: background work suspended for another {} min (restored from settings)",
            (until - now_ms()) / 60_000
        );
    }
    if compute.mode() != afterray_protocol::ComputeMode::Full {
        eprintln!("compute: mode is {}", compute.mode().as_label());
    }
    let capture_busy = Arc::new(AtomicBool::new(false));
    let capture_paused = Arc::new(AtomicBool::new(false));
    let last_capture_ms = Arc::new(AtomicI64::new(0));
    let recording_active = Arc::new(AtomicBool::new(false));
    let app_anchor = parent_app_anchor();
    if app_anchor.is_none() {
        eprintln!("no AfterRay parent to pin; socket clients stay on the CLI query surface");
    }
    let state = Arc::new(AppState {
        store,
        capture,
        models,
        recording: Mutex::new(RecordingRuntime::default()),
        capture_lifecycle: CaptureLifecycle::default(),
        download: std::sync::Mutex::new(None),
        download_queue: std::sync::Mutex::new(Vec::new()),
        download_active: AtomicBool::new(false),
        download_cancellation: std::sync::Mutex::new(None),
        download_paused: AtomicBool::new(false),
        download_cancel_requested: AtomicBool::new(false),
        download_drop_pack: std::sync::Mutex::new(None),
        download_changed: tokio::sync::Notify::new(),
        asr_changed: tokio::sync::Notify::new(),
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
        capture_paused,
        capture_display: std::sync::Mutex::new(None),
        last_capture_ms,
        recording_active,
        excluded_bundle_ids: std::sync::Mutex::new(persisted.excluded_bundle_ids.clone()),
        excluded_domains: std::sync::Mutex::new(persisted.excluded_domains.clone()),
        model_download_endpoint: std::sync::Mutex::new(persisted.model_download_endpoint.clone()),
        memories: std::sync::Mutex::new(memory::MemoryRuntime::default()),
        languages: std::sync::Mutex::new((
            persisted.ui_language.clone(),
            persisted.summary_language.clone(),
        )),
        cli_evidence_until_ms: std::sync::Mutex::new(persisted.cli_evidence_until_ms),
        app_anchor,
        llm_config,
        llm_token_sink,
        mlx_adapters,
        compute,
        backlog: tokio::sync::Mutex::new(None),
        t2_changed: tokio::sync::Notify::new(),
        running_turns: Arc::new(std::sync::Mutex::new(HashMap::new())),
        draining: AtomicBool::new(false),
        lifecycle: BackgroundLifecycle::default(),
    });

    // Off the boot path: `recent_summary_runs` sorts an unindexed column, and
    // nothing in the daemon's first seconds needs the answer — the panel is not
    // open yet, and `seed_summaries` no-ops once a live pass has been recorded.
    {
        let seed_store = Arc::clone(&state.store);
        let seed_compute = Arc::clone(&state.compute);
        state
            .lifecycle
            .track_task(tokio::task::spawn_blocking(move || {
                seed_summary_history(&seed_store, &seed_compute);
            }));
    }

    settle_orphaned_turns(&state);
    {
        let removed =
            reclaim_abandoned_downloads(&model_directory(), &std::collections::HashSet::new());
        if removed > 0 {
            eprintln!("reclaimed {removed} abandoned model download staging dir(s) older than 24h");
        }
    }
    println!("afterrayd listening on {}", socket.display());
    let migration_store = Arc::clone(&state.store);
    state
        .lifecycle
        .track_task(tokio::task::spawn_blocking(move || {
            match migration_store.run_artifact_maintenance() {
                Ok(0) => {}
                Ok(count) => eprintln!("migrated {count} legacy artifact(s) in the background"),
                Err(error) => eprintln!("background artifact maintenance paused: {error}"),
            }
        }));
    spawn_gop_packer(Arc::clone(&state));
    spawn_slot_summarizer(Arc::clone(&state));
    spawn_mlx_idle_reaper(Arc::clone(&state));
    spawn_text_df_maintainer(Arc::clone(&state));
    spawn_asr_sweeper(Arc::clone(&state));
    if gpu_probe_enabled {
        spawn_gpu_sampler(Arc::clone(&state));
    }

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                // Belt to the socket's `0600` braces: the permission bits are
                // checked when the path is opened, this is checked on the
                // connection we actually got.
                match stream.peer_cred() {
                    Ok(peer) if peer.uid() == owner_uid => {}
                    Ok(peer) => {
                        eprintln!("refused a connection from uid {}", peer.uid());
                        continue;
                    }
                    Err(error) => {
                        eprintln!("refused a connection with unreadable credentials: {error}");
                        continue;
                    }
                }
                let task_state = Arc::clone(&state);
                let task = tokio::spawn(async move {
                    if let Err(error) = handle(stream, task_state).await {
                        eprintln!("client error: {error:#}");
                    }
                });
                state.lifecycle.track_task(task);
            }
            () = &mut shutdown => break,
            changed = shutdown_rx.changed() => {
                if changed.is_ok() && *shutdown_rx.borrow() {
                    break;
                }
            }
        }
    }

    state.begin_draining();
    let shutdown_started = Instant::now();
    cancel_disposable_work(&state).await;
    // The helper wait and failed-helper recovery are bounded inside `record_stop`.
    // A healthy consumer drain, memory flush, and session close are required
    // durability work and must not be cancelled by an outer timeout.
    let response = record_stop(&state, Some("shutdown")).await;
    if !response.ok {
        eprintln!(
            "could not finish the active session during shutdown: {}",
            response.error.as_deref().unwrap_or("unknown error")
        );
    }
    if let Err(error) = clear_stale_capture_files(&staging_dir) {
        eprintln!("could not clear capture staging during shutdown: {error}");
    }
    state
        .lifecycle
        .cancel_and_join(Duration::from_millis(750))
        .await;
    drop(listener);
    let _ = std::fs::remove_file(&socket);
    eprintln!(
        "shutdown: daemon drain completed in {} ms",
        shutdown_started.elapsed().as_millis()
    );
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

// @dec:mlx-asr-runtime — docs/decisions/active/architecture/2026-08-25-mlx-asr-runtime.md
fn local_model_adapters(
    native_worker: PathBuf,
    general_worker: PathBuf,
    mlx_worker: PathBuf,
    mlx_asr_worker: PathBuf,
    llm_config: Arc<std::sync::Mutex<LlmRuntimeConfig>>,
) -> (
    Vec<Arc<dyn ModelAdapter>>,
    LlmTokenSink,
    Vec<(String, Arc<PersistentMlxAdapter>)>,
) {
    let mlx_4b = new_mlx_adapter(
        &mlx_worker,
        QWEN35_4B_MLX_PACK_ID,
        QWEN35_4B_MLX_REVISION,
        qwen35_mlx_manifest(),
    );
    let mlx_9b = new_mlx_adapter(
        &mlx_worker,
        QWEN35_9B_MLX_PACK_ID,
        QWEN35_9B_MLX_REVISION,
        qwen35_9b_mlx_manifest(),
    );
    let llm = LlmRouterAdapter::new(llm_config)
        .with_mlx(QWEN35_4B_MLX_PACK_ID, Arc::clone(&mlx_4b))
        .with_mlx(QWEN35_9B_MLX_PACK_ID, Arc::clone(&mlx_9b));
    let token_sink = llm.token_sink();
    let asr_model_dir = spec_by_id("asr")
        .map(|spec| spec.path)
        .unwrap_or_else(|| model_directory().join("Qwen3-ASR-1.7B-MLX-4bit"));
    let mut mlx_asr_config = ProcessAdapterConfig::new(
        "qwen3-asr-mlx",
        ModelCapability::Asr,
        mlx_asr_worker,
    );
    mlx_asr_config
        .env
        .insert("AFTERRAY_ASR_MODEL".into(), asr_model_dir.display().to_string());
    (
        vec![
            Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
                "vision-ocr",
                ModelCapability::Ocr,
                native_worker,
            ))) as Arc<dyn ModelAdapter>,
            Arc::new(ProcessAdapter::new(mlx_asr_config)),
            Arc::new(ProcessAdapter::new(ProcessAdapterConfig::new(
                "llama-embedding",
                ModelCapability::Embedding,
                general_worker,
            ))),
            Arc::new(llm),
        ],
        token_sink,
        vec![
            (QWEN35_4B_MLX_PACK_ID.into(), mlx_4b),
            (QWEN35_9B_MLX_PACK_ID.into(), mlx_9b),
        ],
    )
}

fn new_mlx_adapter(
    worker: &Path,
    pack_id: &str,
    revision: &str,
    manifest: Vec<afterray_models::ManifestFile>,
) -> Arc<PersistentMlxAdapter> {
    let model_dir = spec_by_id(pack_id)
        .map(|spec| spec.path)
        .unwrap_or_else(|| model_directory().join(pack_id));
    let mut mlx_config = PersistentMlxConfig::new(worker, model_dir);
    mlx_config.revision = revision.into();
    mlx_config.manifest = manifest;
    Arc::new(PersistentMlxAdapter::new(mlx_config))
}

fn resolve_helper_path(env_key: &str, helper_name: &str, development_path: &str) -> PathBuf {
    if let Some(path) = std::env::var_os(env_key).filter(|value| !value.is_empty()) {
        return PathBuf::from(path);
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        let bundled = directory.join(helper_name);
        if bundled.is_file() {
            return bundled;
        }
    }
    PathBuf::from(development_path)
}

#[derive(Default)]
struct BackgroundTaskRegistry {
    next_id: AtomicU64,
    active: std::sync::Mutex<HashMap<u64, tokio::task::AbortHandle>>,
    changed: tokio::sync::Notify,
}

#[derive(Default)]
struct BackgroundLifecycle {
    tasks: Arc<BackgroundTaskRegistry>,
    threads: std::sync::Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl BackgroundLifecycle {
    fn track_task(&self, task: JoinHandle<()>) {
        let id = self.tasks.next_id.fetch_add(1, Ordering::Relaxed);
        self.tasks
            .active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id, task.abort_handle());
        let registry = Arc::clone(&self.tasks);
        // The reaper is deliberately detached: it owns the JoinHandle and
        // removes the registry entry as soon as the tracked task completes.
        // It is itself bounded by that task and holds no daemon resources.
        drop(tokio::spawn(async move {
            let _ = task.await;
            registry
                .active
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&id);
            registry.changed.notify_waiters();
        }));
    }

    fn track_thread(&self, thread: std::thread::JoinHandle<()>) {
        self.threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(thread);
    }

    fn abort_tasks(&self) -> usize {
        let tasks = self
            .tasks
            .active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for task in tasks.values() {
            task.abort();
        }
        tasks.len()
    }

    fn active_task_count(&self) -> usize {
        self.tasks
            .active
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }

    async fn wait_for_tasks_until(&self, deadline: Instant) -> usize {
        loop {
            // Register before reading the count so completion cannot happen
            // between the observation and the wait without waking us.
            let changed = self.tasks.changed.notified();
            let active = self.active_task_count();
            if active == 0 {
                return 0;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() || tokio::time::timeout(remaining, changed).await.is_err() {
                return self.active_task_count();
            }
        }
    }

    async fn cancel_and_join(&self, budget: Duration) {
        let started = Instant::now();
        let deadline = Instant::now() + budget;
        let task_count = self.abort_tasks();
        let task_timeouts = self.wait_for_tasks_until(deadline).await;

        let mut threads = {
            let mut tracked = self
                .threads
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            std::mem::take(&mut *tracked)
        };
        let thread_count = threads.len();
        while !threads.is_empty() && Instant::now() < deadline {
            let mut index = 0;
            while index < threads.len() {
                if threads[index].is_finished() {
                    let thread = threads.swap_remove(index);
                    let _ = thread.join();
                } else {
                    index += 1;
                }
            }
            if !threads.is_empty() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
        let thread_timeouts = threads.len();
        drop(threads);
        eprintln!(
            "shutdown: background lifecycle tasks={task_count} timed_out={task_timeouts} threads={thread_count} timed_out={thread_timeouts} elapsed_ms={}",
            started.elapsed().as_millis()
        );
    }
}

async fn finish_required_recording_close<M, S, MemoryResult, SessionResult>(
    memory_flush: M,
    session_close: S,
) -> (MemoryResult, SessionResult)
where
    M: std::future::Future<Output = MemoryResult>,
    S: std::future::Future<Output = SessionResult>,
{
    let memory_result = memory_flush.await;
    let session_result = session_close.await;
    (memory_result, session_result)
}

#[derive(Debug, PartialEq, Eq)]
enum CaptureConsumerOutcome {
    Stopped,
    Failed(String),
}

fn capture_consumer_join_result(
    result: Result<CaptureConsumerOutcome, tokio::task::JoinError>,
) -> Option<String> {
    match result {
        Ok(CaptureConsumerOutcome::Stopped) => None,
        Ok(CaptureConsumerOutcome::Failed(error)) => Some(error),
        Err(error) => Some(format!("capture event consumer failed: {error}")),
    }
}

/// Drains events already emitted by the capture helper.
///
/// A successful helper stop promises a finite stream ending in `Stopped`, so
/// importing every event ahead of it is required durability work. Only a
/// helper that already failed or was forced down gets the short recovery
/// window; the supervisor remains the outer bound for wedged durable I/O.
async fn drain_capture_consumer(
    consumer: Option<JoinHandle<CaptureConsumerOutcome>>,
    helper_failed: bool,
    operation: &str,
) -> Option<String> {
    let Some(mut consumer) = consumer else {
        return None;
    };
    if !helper_failed {
        return capture_consumer_join_result(consumer.await);
    }

    const FAILED_HELPER_DRAIN_BUDGET: Duration = Duration::from_millis(250);
    match tokio::time::timeout(FAILED_HELPER_DRAIN_BUDGET, &mut consumer).await {
        Ok(result) => capture_consumer_join_result(result),
        Err(_) => {
            consumer.abort();
            // Aborting only schedules cancellation. Join it before a wake-side
            // start can create another helper, or this old consumer can still
            // win the shared event receiver and steal the new `Ready`.
            let _ = consumer.await;
            eprintln!(
                "{operation}: failed capture helper's event consumer timed out after {} ms and was cancelled",
                FAILED_HELPER_DRAIN_BUDGET.as_millis()
            );
            Some("capture event consumer timed out".to_owned())
        }
    }
}

async fn finish_recording_after_helper_stop<M, S, MemoryResult, SessionResult>(
    consumer: Option<JoinHandle<CaptureConsumerOutcome>>,
    helper_failed: bool,
    operation: &str,
    memory_flush: M,
    session_close: S,
) -> (Option<String>, MemoryResult, SessionResult)
where
    M: std::future::Future<Output = MemoryResult>,
    S: std::future::Future<Output = SessionResult>,
{
    let consumer_error = drain_capture_consumer(consumer, helper_failed, operation).await;
    let (memory_result, session_result) =
        finish_required_recording_close(memory_flush, session_close).await;
    (consumer_error, memory_result, session_result)
}

struct AppState {
    store: Arc<Vault>,
    capture: Arc<MacOsCaptureBackend>,
    models: ModelQueue,
    recording: Mutex<RecordingRuntime>,
    /// Serializes ordinary start/stop RPCs through the old consumer's final
    /// event. `record_stop` publishes logical idle before required drain work,
    /// so a wake-side start must wait here rather than attach a new helper to
    /// the same event receiver. Shutdown bypasses this gate: app termination
    /// already forbids new work and must be able to interrupt a slow startup.
    capture_lifecycle: CaptureLifecycle,
    download: std::sync::Mutex<Option<ModelDownloadProgress>>,
    download_queue: std::sync::Mutex<Vec<afterray_models::PackSpec>>,
    download_active: AtomicBool,
    download_cancellation: std::sync::Mutex<Option<Cancellation>>,
    download_paused: AtomicBool,
    download_cancel_requested: AtomicBool,
    /// Pack id the user cancelled on its own. `download_cancel_requested` tears
    /// the whole queue down; this drops exactly one pack and lets the worker
    /// carry on with the rest.
    download_drop_pack: std::sync::Mutex<Option<String>>,
    download_changed: tokio::sync::Notify,
    asr_changed: tokio::sync::Notify,
    capture_interval: Duration,
    data_dir: PathBuf,
    shutdown: tokio::sync::watch::Sender<bool>,
    packer: Arc<gop_packer::GopPacker>,
    capture_busy: Arc<AtomicBool>,
    /// Set by `CaptureSetPaused` while the app's overlay is frontmost. The
    /// scheduler keeps ticking but skips the screenshot, so the recording
    /// session — and the shim's audio — run on uninterrupted.
    capture_paused: Arc<AtomicBool>,
    /// Logical size of the display the shim is capturing, from its `Ready`
    /// event. The only place the daemon learns a screenshot's dimensions, and
    /// therefore the only way to map Vision's normalized OCR boxes onto the
    /// accessibility tree's screen points ([`ocr_crop`]). `None` until a
    /// capture session has started; a stale value from a previous session is
    /// overwritten before that session's first moment exists.
    capture_display: std::sync::Mutex<Option<ocr_crop::DisplayPoints>>,
    last_capture_ms: Arc<AtomicI64>,
    recording_active: Arc<AtomicBool>,
    excluded_bundle_ids: std::sync::Mutex<Vec<String>>,
    excluded_domains: std::sync::Mutex<Vec<String>>,
    /// Mirror model downloads resolve against; empty means huggingface.co.
    /// The live value lives in `afterray_models` (`set_huggingface_endpoint`);
    /// this copy only feeds settings responses and persistence.
    model_download_endpoint: std::sync::Mutex<String>,
    memories: std::sync::Mutex<memory::MemoryRuntime>,
    /// (ui_language, summary_language) as stored preferences; `auto` until
    /// the user picks, resolved against the system locale at prompt time.
    languages: std::sync::Mutex<(String, String)>,
    /// Close of the CLI evidence window. `None` or a past instant is off.
    cli_evidence_until_ms: std::sync::Mutex<Option<i64>>,
    /// AfterRay.app that spawned us (Team ID and/or cdhash). Absent when
    /// afterrayd was started from a shell — then nobody is privileged.
    app_anchor: Option<afterray_platform_macos::CodeIdentity>,
    llm_config: Arc<std::sync::Mutex<LlmRuntimeConfig>>,
    llm_token_sink: LlmTokenSink,
    mlx_adapters: Vec<(String, Arc<PersistentMlxAdapter>)>,
    /// Decides whether background computation may run, and describes that
    /// decision to the dashboard. Interactive work never consults it.
    compute: Arc<compute::ComputeGovernor>,
    /// Last durable backlog count and when it was taken. Cached because the
    /// dashboard polls every couple of seconds and the count walks `moments`
    /// against `text_evidence` — cheap once, wasteful sixty times a minute.
    backlog: tokio::sync::Mutex<Option<(std::time::Instant, BacklogCounts)>>,
    /// Wakes the summary sweeper without waiting out its five-minute tick, so
    /// "run now" starts within a second rather than eventually.
    t2_changed: tokio::sync::Notify,
    /// Cancel tokens for turns currently running, by conversation.
    ///
    /// A `ChatAbort` arrives on a *different* connection from the stream it
    /// stops — the stream's own connection is busy writing events — so the
    /// token has to be reachable by name.
    running_turns: Arc<crate::stream::RunningTurns>,
    /// Set only after the shutdown ACK has been written (or immediately for an
    /// OS signal). Every request and long-lived loop treats it as a hard gate.
    draining: AtomicBool,
    lifecycle: BackgroundLifecycle,
}

// @dec:bounded-shutdown — docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md
impl AppState {
    fn begin_draining(&self) {
        if !self.draining.swap(true, Ordering::AcqRel) {
            let _ = self.shutdown.send(true);
        }
    }
}

async fn cancel_disposable_work(state: &Arc<AppState>) {
    let started = Instant::now();
    state
        .download_cancel_requested
        .store(true, Ordering::Release);
    if let Some(cancellation) = state
        .download_cancellation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        cancellation.cancel();
    }
    state.download_changed.notify_waiters();

    let turn_tokens: Vec<_> = state
        .running_turns
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .values()
        .cloned()
        .collect();
    for token in &turn_tokens {
        token.cancel();
    }
    let model_jobs = state.models.shutdown().await;
    let tasks = state.lifecycle.abort_tasks();

    let mlx_result = tokio::time::timeout(Duration::from_millis(750), async {
        for (_, adapter) in &state.mlx_adapters {
            adapter.shutdown().await;
        }
    })
    .await;
    eprintln!(
        "shutdown: cancelled downloads, {} turn(s), {model_jobs} model job(s), {tasks} task(s); mlx={} elapsed_ms={}",
        turn_tokens.len(),
        if mlx_result.is_ok() {
            "stopped"
        } else {
            "timeout"
        },
        started.elapsed().as_millis()
    );
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct PersistedSettings {
    #[serde(default = "default_record_audio")]
    record_audio: bool,
    #[serde(default = "default_storage_limit_bytes")]
    storage_limit_bytes: u64,
    #[serde(default = "default_excluded_bundle_ids")]
    excluded_bundle_ids: Vec<String>,
    #[serde(default)]
    excluded_domains: Vec<String>,
    #[serde(default)]
    llm_provider: LlmProvider,
    #[serde(default)]
    llm_base_url: String,
    #[serde(default)]
    llm_model: String,
    /// Read so a `settings.json` written before the key moved into the
    /// Keychain can be migrated. Never written back.
    #[serde(rename = "llm_api_key", default, skip_serializing)]
    legacy_llm_api_key: String,
    #[serde(default = "default_language")]
    ui_language: String,
    #[serde(default = "default_language")]
    summary_language: String,
    #[serde(default)]
    model_download_endpoint: String,
    /// How much background computation is allowed. Persisted so the choice
    /// survives the restart that an app update performs.
    #[serde(default)]
    compute_mode: afterray_protocol::ComputeMode,
    /// Deadline of a user-requested suspension, epoch-ms; `0` means none.
    ///
    /// A deadline rather than a remaining duration: a daemon that restarts
    /// twice during the hour must not extend the hour twice.
    #[serde(default)]
    compute_paused_until_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cli_evidence_until_ms: Option<i64>,
}

/// How often the T2 sweeper wakes. `0` disables it, which the dashboard reports
/// as "disabled at launch" rather than pretending the switch works.
fn t2_sweep_period() -> Duration {
    Duration::from_secs(
        std::env::var("AFTERRAY_T2_SWEEP_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(300),
    )
}

fn default_language() -> String {
    "auto".to_owned()
}

/// Reply language for chat and ask, from the stored **summary** preference.
pub(crate) fn reply_language(state: &AppState) -> String {
    let (ui, summary) = state.languages.lock().map_or_else(
        |_| (default_language(), default_language()),
        |langs| langs.clone(),
    );
    agent::reply_language_from_prefs(&ui, &summary)
}

const fn default_record_audio() -> bool {
    true
}

const fn default_storage_limit_bytes() -> u64 {
    DEFAULT_STORAGE_LIMIT_BYTES
}

impl Default for PersistedSettings {
    fn default() -> Self {
        Self {
            record_audio: true,
            storage_limit_bytes: DEFAULT_STORAGE_LIMIT_BYTES,
            excluded_bundle_ids: default_excluded_bundle_ids(),
            excluded_domains: Vec::new(),
            llm_provider: LlmProvider::MlxLocal,
            llm_base_url: String::new(),
            llm_model: String::new(),
            legacy_llm_api_key: String::new(),
            ui_language: default_language(),
            summary_language: default_language(),
            model_download_endpoint: String::new(),
            compute_mode: afterray_protocol::ComputeMode::Full,
            compute_paused_until_ms: 0,
            cli_evidence_until_ms: None,
        }
    }
}

#[derive(Default)]
struct RecordingRuntime {
    active_session_id: Option<String>,
    captured_frame: bool,
    scheduler: Option<JoinHandle<()>>,
    event_consumer: Option<JoinHandle<CaptureConsumerOutcome>>,
}

#[derive(Default)]
struct CaptureLifecycle {
    gate: Mutex<()>,
}

impl CaptureLifecycle {
    async fn enter(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.gate.lock().await
    }
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
    let privileged = client_is_privileged(&stream, &state);
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        match serde_json::from_str::<Request>(&line) {
            Ok(request) if !privileged => {
                if let Err(message) =
                    authorize_cli_request(&request, cli_evidence_until_ms(&state), now_ms())
                {
                    write_json_response(&mut write, &Response::failure(message)).await?;
                    continue;
                }
                handle_authorized_request(request, &state, &mut write, &mut lines, false).await?;
            }
            Ok(request) => {
                handle_authorized_request(request, &state, &mut write, &mut lines, true).await?;
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

fn client_is_privileged(stream: &UnixStream, state: &AppState) -> bool {
    use std::os::fd::AsRawFd as _;
    peer_is_afterray_app(stream.as_raw_fd(), state.app_anchor.as_ref())
}

fn cli_evidence_until_ms(state: &AppState) -> Option<i64> {
    state
        .cli_evidence_until_ms
        .lock()
        .map(|until| *until)
        .unwrap_or(None)
}

#[allow(clippy::too_many_lines)]
async fn handle_authorized_request(
    request: Request,
    state: &Arc<AppState>,
    write: &mut tokio::net::unix::OwnedWriteHalf,
    lines: &mut tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    privileged: bool,
) -> anyhow::Result<()> {
    if state.draining.load(Ordering::Acquire) && !matches!(&request, Request::Shutdown) {
        write_json_response(write, &Response::failure("daemon is shutting down")).await?;
        return Ok(());
    }
    match request {
        Request::Shutdown => {
            acknowledge_shutdown(write, || state.begin_draining()).await?;
        }
        // Artifact / thumbnail reads decrypt on the blocking pool. Doing
        // that on a worker used to freeze accepts and chat streams while
        // the filmstrip scrubbed.
        Request::ReadArtifact { artifact_id } => {
            let result = run_store(state, move |s| read_still_artifact(s, &artifact_id)).await;
            write_artifact_response(write, result).await?;
        }
        Request::ReadGopSegment { segment_id } => {
            let result = run_store(state, move |s| s.store.read_gop_artifact(&segment_id)).await;
            write_artifact_response(write, result).await?;
        }
        Request::ReadGopFrame {
            segment_id,
            index,
            mode,
        } => {
            let result = run_store(state, move |s| {
                gop_packer::read_gop_frame(&s.store, &segment_id, index, mode)
            })
            .await;
            write_artifact_response(write, result).await?;
        }
        Request::ChatStream {
            conversation_id,
            message,
        } => {
            // A hang-up no longer cancels. Closing the panel means "I will
            // read it later": the turn runs on and writes itself into its
            // row, so coming back finds the finished answer. Only an
            // explicit ChatAbort stops a turn — see Request::ChatAbort.
            let cancel = afterray_harness::CancelToken::new();
            let (result, _peer_present) = stream::run_watching_for_hangup(
                stream::handle_chat_stream(write, state, conversation_id, message, cancel.clone()),
                lines,
            )
            .await;
            result?;
        }
        Request::ReadThumbnail {
            moment_id,
            max_edge,
        } => {
            let result = run_store(state, move |s| {
                read_moment_thumbnail(&s.store, &moment_id, max_edge)
            })
            .await;
            write_artifact_response(write, result).await?;
        }
        other => {
            let mut response = dispatch(other.clone(), state).await;
            if !privileged && let Some(data) = response.data.as_mut() {
                redact_cli_response_data(&other, data);
            }
            write_json_response(write, &response).await?;
        }
    }
    Ok(())
}

async fn write_json_response<W>(write: &mut W, response: &Response) -> anyhow::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut encoded = serde_json::to_vec(response)?;
    encoded.push(b'\n');
    write.write_all(&encoded).await?;
    Ok(())
}

/// The ACK is the handoff contract with the app: it must be fully written
/// before draining can stop the socket handler or tear the runtime down.
async fn acknowledge_shutdown<W, F>(write: &mut W, begin_draining: F) -> anyhow::Result<()>
where
    W: AsyncWrite + Unpin,
    F: FnOnce(),
{
    write_json_response(
        write,
        &Response::success(serde_json::json!({
            "stopping": true,
            "pid": std::process::id(),
        })),
    )
    .await?;
    begin_draining();
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

/// Runs store/CPU-heavy work on the blocking pool. Every synchronous Vault
/// call made directly from async context occupies a tokio worker for its
/// whole duration; a handful of card builds used to freeze the entire async
/// surface — socket accepts and chat streams included.
async fn run_store<T, F>(state: &Arc<AppState>, task: F) -> T
where
    F: FnOnce(&AppState) -> T + Send + 'static,
    T: Send + 'static,
{
    let state = Arc::clone(state);
    tokio::task::spawn_blocking(move || task(&state))
        .await
        .expect("blocking store task panicked")
}

/// A row still marked `streaming` means the daemon died mid-turn and nothing
/// will ever finish it. Left alone it would show a live spinner forever.
fn settle_orphaned_turns(state: &AppState) {
    match state.store.settle_orphaned_streams() {
        Ok(0) => {}
        Ok(count) => eprintln!("chat: settled {count} turn(s) orphaned by a previous run"),
        Err(error) => eprintln!("chat: could not settle orphaned turns: {error}"),
    }
}

/// Stops the turn running on a conversation, if one is.
fn abort_turn(state: &AppState, conversation_id: &str) -> Response {
    let token = state
        .running_turns
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(conversation_id)
        .cloned();
    match token {
        Some(token) => {
            token.cancel();
            Response::success(serde_json::json!({"aborted": true}))
        }
        // Not an error: the turn may have finished between the user pressing
        // stop and this arriving, which is a race the app should not report.
        None => Response::success(serde_json::json!({"aborted": false})),
    }
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
                host_build: std::env::var("AFTERRAY_HOST_BUILD")
                    .ok()
                    .filter(|v| !v.is_empty()),
                cli_evidence_until_ms: cli_evidence_until_ms(state),
            })
        }
        Request::RecordStart => record_start(state).await,
        Request::RecordStop { reason } => record_stop(state, reason.as_deref()).await,
        Request::CaptureSetPaused { paused, reason } => {
            state.capture_paused.store(paused, Ordering::SeqCst);
            eprintln!(
                "capture_set_paused: paused={paused} reason={}",
                reason.as_deref().unwrap_or("-")
            );
            Response::success(serde_json::json!({"capture_paused": paused}))
        }
        // Every Vault touch below goes through `run_store`. The async surface
        // (accepts, Status/Ping, chat stream IO) stays on workers; SQLite and
        // decrypt stay on the blocking pool.
        Request::SessionsList => run_store(state, |s| into_response(s.store.sessions_sync())).await,
        Request::TimelineList => run_store(state, |s| into_response(s.store.timeline_sync())).await,
        Request::TimelineSince { since_ms } => {
            run_store(state, move |s| {
                into_response(s.store.timeline_since_sync(since_ms))
            })
            .await
        }
        Request::TimelineRange { from_ms, to_ms } => {
            run_store(state, move |s| {
                into_response(s.store.timeline_range_sync(from_ms, to_ms))
            })
            .await
        }
        Request::MomentsList { session_id } => {
            run_store(state, move |s| {
                into_response(s.store.moments_sync(&session_id))
            })
            .await
        }
        Request::RecallWindow {
            session_id,
            center_ms,
            limit,
        } => {
            run_store(state, move |s| match s.store.moments_sync(&session_id) {
                Ok(mut moments) => {
                    moments.sort_by_key(|moment| moment.captured_at_ms.abs_diff(center_ms));
                    moments.truncate(limit.clamp(1, 500));
                    moments.sort_by_key(|moment| moment.captured_at_ms);
                    Response::success(moments)
                }
                Err(error) => Response::failure(error.to_string()),
            })
            .await
        }
        Request::ReadArtifact { .. }
        | Request::ReadGopSegment { .. }
        | Request::ReadGopFrame { .. }
        | Request::ReadThumbnail { .. } => Response::failure(
            "artifact reads are framed as a JSON header plus raw bytes and are handled separately",
        ),
        Request::ChatStream { .. } => {
            Response::failure("chat streams are framed as NDJSON events and are handled separately")
        }
        Request::ChatAbort { conversation_id } => abort_turn(state, &conversation_id),
        Request::PackStatus => run_store(state, |s| pack_status(s)).await,
        Request::GopShow { segment_id } => {
            run_store(state, move |s| {
                into_response(s.store.gop_segment_view(&segment_id))
            })
            .await
        }
        Request::FavoriteSet { .. } => Response::failure("favorites are disabled"),
        Request::Search {
            query,
            limit,
            from_ms,
            to_ms,
        } => {
            run_store(state, move |s| {
                match text_hits(&s.store, &query, limit.clamp(1, 100)) {
                    Ok(mut hits) => {
                        if let (Some(from), Some(to)) = (from_ms, to_ms) {
                            let (from, to) = if from <= to { (from, to) } else { (to, from) };
                            hits.retain(|hit| {
                                hit.captured_at_ms >= from && hit.captured_at_ms <= to
                            });
                        }
                        Response::success(hits)
                    }
                    Err(error) => Response::failure(error.to_string()),
                }
            })
            .await
        }
        Request::MomentGet { moment_id } => {
            run_store(state, move |s| {
                match tools::moment_detail(afterray_store::ReadOnlyVault::new(&s.store), &moment_id)
                {
                    Ok(moment) => Response::success(moment),
                    Err(error) => Response::failure(error),
                }
            })
            .await
        }
        Request::MomentAt { at_ms } => {
            run_store(state, move |s| match s.store.moment_nearest(at_ms) {
                Ok(Some(moment_id)) => {
                    match tools::moment_detail(
                        afterray_store::ReadOnlyVault::new(&s.store),
                        &moment_id,
                    ) {
                        Ok(moment) => Response::success(moment),
                        Err(error) => Response::failure(error),
                    }
                }
                Ok(None) => Response::failure("no moment has been captured yet"),
                Err(error) => Response::failure(error.to_string()),
            })
            .await
        }
        Request::SlotCard { at_ms } => {
            run_store(state, move |s| into_response(slot_card_for(s, at_ms))).await
        }
        Request::SlotSummarize { at_ms } => slot_summarize(state, at_ms).await,
        Request::SlotBackfill { days } => slot_backfill(state, days).await,
        Request::SlotSummaryExport { at_ms } => {
            run_store(state, move |s| {
                let interval_ms = i64::try_from(s.capture_interval.as_millis()).unwrap_or(10_000);
                into_response(s.store.slot_summary_export(at_ms, interval_ms))
            })
            .await
        }
        Request::DaySummary { day_ms } => {
            run_store(state, move |s| {
                let interval_ms = i64::try_from(s.capture_interval.as_millis()).unwrap_or(10_000);
                into_response(s.store.day_summary(day_ms, interval_ms))
            })
            .await
        }
        Request::SlotPrompt { at_ms } => {
            // The same budget the summariser would use, probed the same way:
            // an inspection that showed a different prompt than the one the
            // model gets would be worse than no inspection.
            let budget_chars = t2_prompt_budget_chars(ContextBudget {
                max_rounds: T2_MAX_ROUNDS,
                ..resolve_context_budget(state).await
            });
            run_store(state, move |s| {
                match slot_prompt_for(s, at_ms, budget_chars) {
                    Ok(prompt) => Response::success(prompt),
                    Err(error) => Response::failure(error.to_string()),
                }
            })
            .await
        }
        Request::SummaryHistory { before_ms, limit } => {
            // Multi-day summary assembly is exactly the class of work the
            // blocking pool exists for.
            run_store(state, move |s| {
                let interval_ms = i64::try_from(s.capture_interval.as_millis()).unwrap_or(10_000);
                into_response(s.store.summary_history(before_ms, limit, interval_ms))
            })
            .await
        }
        Request::EvidenceOcr { moment_id } => {
            run_store(state, move |s| {
                match tools::ocr_evidence(afterray_store::ReadOnlyVault::new(&s.store), &moment_id)
                {
                    Ok(evidence) => Response::success(evidence),
                    Err(error) => Response::failure(error),
                }
            })
            .await
        }
        Request::EvidenceAx {
            moment_id,
            digest_only,
        } => {
            run_store(state, move |s| {
                match tools::ax_evidence(
                    afterray_store::ReadOnlyVault::new(&s.store),
                    &moment_id,
                    digest_only,
                ) {
                    Ok(evidence) => Response::success(evidence),
                    Err(error) => Response::failure(error),
                }
            })
            .await
        }
        Request::ActivitySpans {
            from_ms,
            to_ms,
            limit,
        } => {
            run_store(state, move |s| {
                into_response(s.store.activity_spans(from_ms, to_ms, limit.clamp(1, 500)))
            })
            .await
        }
        Request::ModelsStatus => Response::success(model_library(state)),
        Request::ComputeStatus => Response::success(compute_status(state).await),
        Request::ComputeSetMode { mode } => {
            state.compute.set_mode(mode);
            if let Err(error) = persist_current_settings(state) {
                return Response::failure(format!("could not save the compute mode: {error}"));
            }
            eprintln!("compute: mode set to {}", mode.as_label());
            Response::success(compute_status(state).await)
        }
        Request::ComputeRunNow { workload } => {
            if let Some(refusal) = state.compute.force_refusal(workload, now_ms()) {
                return Response::failure(refusal.reason);
            }
            state.compute.force_now(workload, now_ms());
            // The counts this is about to change are cached; drop it so the next
            // poll shows the pile actually moving.
            state.backlog.lock().await.take();
            // Persisted because `force_now` lifts an active suspension, and that
            // must not come back on the next restart.
            if let Err(error) = persist_current_settings(state) {
                eprintln!("compute: could not save the lifted suspension: {error}");
            }
            // Wake the loop instead of letting it find out on its next tick: a
            // button that takes five minutes to visibly do anything reads as
            // broken.
            match workload {
                afterray_protocol::ComputeWorkload::Summary => state.t2_changed.notify_one(),
                afterray_protocol::ComputeWorkload::Asr => state.asr_changed.notify_one(),
                // The packer polls on a one-second sleep and the model queue
                // starts work as it arrives, so neither needs a nudge.
                afterray_protocol::ComputeWorkload::Archive
                | afterray_protocol::ComputeWorkload::Ocr
                | afterray_protocol::ComputeWorkload::Embedding => {}
            }
            eprintln!(
                "compute: running {} now, overriding machine conditions for {}",
                workload.as_label(),
                human_duration(compute::FORCE_WINDOW)
            );
            Response::success(compute_status(state).await)
        }
        Request::ComputePause { seconds } => {
            let until = state.compute.pause_for(now_ms(), seconds);
            if let Err(error) = persist_current_settings(state) {
                return Response::failure(format!("could not save the suspension: {error}"));
            }
            match until {
                Some(until) => eprintln!(
                    "compute: background work suspended for {} min",
                    (until - now_ms()) / 60_000
                ),
                None => eprintln!("compute: background work resumed"),
            }
            Response::success(compute_status(state).await)
        }
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
            let model = ready_model(state).await;
            ask::handle_ask(
                &state.store,
                &state.models,
                &question,
                from_ms,
                to_ms,
                now_ms(),
                model,
                &reply_language(state),
            )
            .await
        }
        Request::ChatSend {
            conversation_id,
            message,
        } => {
            let model = ready_model(state).await;
            chat::handle_send(
                &state.store,
                &state.models,
                conversation_id.as_deref(),
                &message,
                now_ms(),
                model,
                &reply_language(state),
            )
            .await
        }
        Request::ChatList => run_store(state, |s| chat::handle_list(&s.store)).await,
        Request::ChatHistory { conversation_id } => {
            run_store(state, move |s| {
                chat::handle_history(&s.store, &conversation_id)
            })
            .await
        }
        Request::ChatDelete { conversation_id } => {
            run_store(state, move |s| {
                chat::handle_delete(&s.store, &conversation_id)
            })
            .await
        }
        Request::Settings => Response::success(current_settings(state)),
        Request::UpdateSettings {
            record_audio,
            ui_language,
            summary_language,
            storage_limit_bytes,
            summary_slot_minutes,
            excluded_bundle_ids,
            excluded_domains,
            llm_provider,
            llm_base_url,
            llm_model,
            llm_api_key,
            model_download_endpoint,
            cli_evidence_access,
        } => {
            update_settings(
                state,
                SettingsPatch {
                    record_audio,
                    ui_language,
                    summary_language,
                    storage_limit_bytes,
                    summary_slot_minutes,
                    excluded_bundle_ids,
                    excluded_domains,
                    llm_provider,
                    llm_base_url,
                    llm_model,
                    llm_api_key,
                    model_download_endpoint,
                    cli_evidence_access,
                },
            )
            .await
        }
        Request::LlmProbe { provider, base_url } => {
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
                probe_llm(provider, base_url.as_deref(), config.api_key.as_deref()).await,
            )
        }
        Request::ClearHistory { scope } => clear_history(state, scope).await,
        Request::MemoriesList {
            from_ms,
            to_ms,
            limit,
        } => {
            run_store(state, move |s| {
                into_response(s.store.memories(from_ms, to_ms, limit.clamp(1, 200)))
            })
            .await
        }
        Request::DownloadModels { pack_id, pack_ids } => {
            start_model_downloads(state, pack_id.as_deref(), &pack_ids)
        }
        Request::PauseModelDownloads => pause_model_downloads(state).await,
        Request::ResumeModelDownloads => resume_model_downloads(state),
        Request::CancelModelDownloads => cancel_model_downloads(state).await,
        Request::CancelModelDownload { pack_id } => cancel_model_download(state, &pack_id).await,
        Request::RemoveModel { pack_id } => remove_model(state, &pack_id).await,
        Request::Shutdown => Response::failure("shutdown is handled by the socket ACK path"),
    }
}

async fn record_start(state: &Arc<AppState>) -> Response {
    let _capture_lifecycle = state.capture_lifecycle.enter().await;
    let _ = run_store(state, |s| s.store.end_open_idle_spans(now_ms())).await;
    let mut recording = state.recording.lock().await;
    if let Some(id) = &recording.active_session_id {
        eprintln!("record_start: already recording session {id}");
        return Response::success(serde_json::json!({"session_id": id, "already_recording": true}));
    }
    let session = match run_store(state, |s| s.store.create_session_sync(now_ms())).await {
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
        let discarded = state.capture.discard_stopped_generation_events().await;
        if discarded > 0 {
            eprintln!("record_start: discarded {discarded} failed startup event(s)");
        }
        let session_id = session.id.clone();
        let _ = run_store(state, move |s| {
            s.store.end_session_sync(&session_id, now_ms())
        })
        .await;
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
    // Before the helper exists, so it holds the list from its first sample
    // buffer. A screenshot can be deleted once the accessibility snapshot
    // names the app; audio cannot, so the helper has to drop it at the source.
    push_audio_exclusions(state).await;
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
            remember_capture_display(state, width, height);
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

    let interval = state.capture_interval;
    let scheduler_state = Arc::clone(state);
    let scheduler = tokio::spawn(async move {
        // Not `tokio::time::interval`: the heartbeat is the *fallback*, and its
        // phase has to follow whatever captured last. An input batch can pull a
        // capture forward (`consume_capture_events`), and sleeping from
        // `last_capture_ms` is how that resets the timer without a channel
        // between the two tasks — the atomic every tick already writes is the
        // whole handshake.
        let interval_ms = i64::try_from(interval.as_millis()).unwrap_or(10_000);
        loop {
            let wait_ms = scheduler_state
                .last_capture_ms
                .load(Ordering::SeqCst)
                .saturating_add(interval_ms)
                .saturating_sub(now_ms());
            if wait_ms > 0 {
                tokio::time::sleep(Duration::from_millis(u64::try_from(wait_ms).unwrap_or(0)))
                    .await;
                continue;
            }
            match fire_capture_tick(&scheduler_state).await {
                CaptureTick::Fired => {}
                // Paused or busy leaves `last_capture_ms` where it was, so the
                // clause above cannot compute a wait: hold off one interval
                // before asking again, as the old interval timer did.
                CaptureTick::Held => tokio::time::sleep(interval).await,
                CaptureTick::Failed => break,
            }
        }
    });

    let event_state = Arc::clone(state);
    let consumer_session = session_id.clone();
    let event_consumer =
        tokio::spawn(async move { consume_capture_events(event_state, consumer_session).await });
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

/// What one attempt to take a screenshot did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureTick {
    Fired,
    /// A gate said no. Nothing was captured and nothing was recorded as
    /// captured — the caller decides when to ask again.
    Held,
    /// The shim could not be asked. The scheduler that owns this session stops.
    Failed,
}

/// One capture tick, wherever it came from.
///
/// Scheduled by the heartbeat or pulled forward by an input batch, a tick is
/// the same act, so it goes through one door with one set of gates: not while
/// the app's overlay is up (`capture_paused`), not while a capture is already
/// in flight (`capture_busy`), and not once the recording that owns the shim is
/// gone (`recording_active`). Two doors would mean two chances to forget one of
/// them.
///
/// The busy claim is a compare-exchange because the two callers now race: the
/// heartbeat's own spacing used to be the only thing keeping a second request
/// off an in-flight one.
///
/// `last_capture_ms` moves *before* the request, not after: it is what the
/// heartbeat sleeps from and what the throttle measures, and both mean "when we
/// last asked for a frame", not "when one came back".
async fn fire_capture_tick(state: &Arc<AppState>) -> CaptureTick {
    if state.capture_paused.load(Ordering::SeqCst) || !state.recording_active.load(Ordering::SeqCst)
    {
        return CaptureTick::Held;
    }
    if state
        .capture_busy
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return CaptureTick::Held;
    }
    state.last_capture_ms.store(now_ms(), Ordering::SeqCst);
    let request_id = Uuid::now_v7().to_string();
    let result = state.capture.capture_screen(&request_id).await;
    state.capture_busy.store(false, Ordering::SeqCst);
    if let Err(error) = result {
        eprintln!("capture request failed: {error}");
        return CaptureTick::Failed;
    }
    CaptureTick::Fired
}

/// The floor under an event-driven screenshot (`docs/event-capture-v2-plan.md`
/// §1). Events arrive at interaction rate; without a floor a fast typist would
/// drive the screenshot path as fast as the shim could answer.
const EVENT_CAPTURE_MIN_INTERVAL_MS: i64 = 10_000;

/// Whether an input batch should pull a screenshot forward.
///
/// The whole decision, as a function of the two facts it depends on, so the
/// wiring around it stays a wiring problem. `interval_ms` is the configured
/// heartbeat: the throttle never goes below the plan's 10s, and never goes
/// below the cadence the user asked for either — a 60s heartbeat means the user
/// wants fewer frames, not 10s frames whenever they type.
///
/// Age is measured from the last capture *request*. `last_capture_ms` of zero
/// or less means nothing has been captured — a session just started, or one
/// stopped and reset — and there is no age to measure, so the interaction is
/// the first thing worth a frame. Said outright rather than left to the epoch
/// making the subtraction large: a throttle that depends on what year it is is
/// not a throttle.
fn event_capture_is_due(
    events_in_batch: usize,
    last_capture_ms: i64,
    now_ms: i64,
    interval_ms: i64,
) -> bool {
    if events_in_batch == 0 {
        return false;
    }
    if last_capture_ms <= 0 {
        return true;
    }
    let throttle_ms = interval_ms.max(EVENT_CAPTURE_MIN_INTERVAL_MS);
    now_ms.saturating_sub(last_capture_ms) >= throttle_ms
}

async fn restart_capture_runtime(state: &Arc<AppState>) -> Result<(), String> {
    let _capture_lifecycle = state.capture_lifecycle.enter().await;
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
    let capture_result = state.capture.stop_capture().await;
    let consumer_error =
        drain_capture_consumer(consumer, capture_result.is_err(), "capture restart").await;
    let discarded = state.capture.discard_stopped_generation_events().await;
    if discarded > 0 {
        eprintln!("capture restart: discarded {discarded} stale generation event(s)");
    }
    match capture_result {
        Ok(()) | Err(CaptureError::NotRunning) => {}
        Err(error) => return Err(error.to_string()),
    }
    if let Some(error) = consumer_error {
        return Err(error);
    }
    start_capture_runtime(state, session_id).await
}

/// Everything a turn needs to know about the model: that there is one, and
/// what window it has.
///
/// The window is worked out here rather than at startup because it is not a
/// property of our settings — it is a property of what the server has loaded
/// right now, and that changes between turns.
pub(crate) async fn ready_model(state: &AppState) -> ask::TurnModel {
    if !ensure_remote_llm_model(state).await {
        return ask::TurnModel::missing();
    }
    ask::TurnModel::ready(resolve_context_budget(state).await)
}

/// Probes the provider for this turn's context window, records it on the shared
/// config so the outgoing request declares the same number, and turns it into a
/// budget.
///
/// Runs per turn. `/api/ps` only reports a window once the model is resident,
/// so a value read at startup would be the wrong one exactly when it mattered;
/// two localhost round trips are cheap next to the generation that follows.
async fn resolve_context_budget(state: &AppState) -> ContextBudget {
    let config = current_llm_config(state);
    let afford = afterray_platform_macos::local_context_tokens();
    let probe = afterray_models::probe_context_tokens(&config, afford).await;
    let changed = {
        let mut llm = state
            .llm_config
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let changed = llm.context_tokens != Some(probe.resolved);
        llm.context_tokens = Some(probe.resolved);
        changed
    };
    // Once per change, not once per turn: the interesting event is the window
    // moving, and a user whose window came out small needs the inputs to know
    // whether it was their machine or their model.
    if changed {
        eprintln!("llm.{}", probe.summary());
    }
    ContextBudget::for_window(probe.resolved)
}

/// Bytes assumed per token when a token budget becomes a character budget.
///
/// Conservative on purpose: real tokenizers average well above this on English
/// prose, and CJK screen text is the case that must not overrun. Written as a
/// ratio because 2.5 is not an integer and rounding it up would spend the
/// margin this exists to keep.
const T2_PROMPT_BYTES_PER_TOKEN_NUMERATOR: usize = 5;
const T2_PROMPT_BYTES_PER_TOKEN_DENOMINATOR: usize = 2;
/// Floor. Exactly the fixed constant this replaced (`PROMPT_LINES_BUDGET_CHARS`
/// in the store), so no machine ever gets a *worse* card than it did before the
/// window became a variable — a small window means fewer rounds, not a card
/// written from four lines.
const T2_PROMPT_FLOOR_CHARS: usize = 12_000;
/// Ceiling: 4× the old fixed budget. Not a limit of the models — a limit of
/// what has been evaluated. The corpus run (WS7) is what lifts it; until then a
/// 256k window buys depth up to here and no further, because an unevaluated
/// 200k-character prompt is a guess with a large bill attached.
const T2_PROMPT_CEILING_CHARS: usize = 48_000;

/// How many characters of evidence one T2 prompt may inline, derived from the
/// window the model actually has.
///
/// The same `resolve_context_budget` chat uses — that asymmetry was a bug: T2
/// planned against a 16k default while chat measured the real window, so the
/// summariser wrote from a twelfth of a 256k model's context and nothing said
/// so. The share taken is the opening allowance: the T2 prompt *is* the
/// opening, and what is left after every round can hold a full tool result.
fn t2_prompt_budget_chars(budget: ContextBudget) -> usize {
    budget
        .opening_allowance()
        .saturating_mul(T2_PROMPT_BYTES_PER_TOKEN_NUMERATOR)
        .checked_div(T2_PROMPT_BYTES_PER_TOKEN_DENOMINATOR)
        .unwrap_or(T2_PROMPT_FLOOR_CHARS)
        .clamp(T2_PROMPT_FLOOR_CHARS, T2_PROMPT_CEILING_CHARS)
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
        storage_limit_bytes: state.store.storage_limit_bytes(),
        // Read from the vault, not `settings.json`: the geometry history lives
        // beside the cards it describes, so there is one source of truth even
        // if the two files ever disagree.
        summary_slot_minutes: summary_slot_minutes(state),
        summary_slot_minutes_options: afterray_protocol::summary_slot_minutes_options(),
        excluded_bundle_ids: state
            .excluded_bundle_ids
            .lock()
            .map(|ids| ids.clone())
            .unwrap_or_default(),
        protected_bundle_ids: protected_bundle_ids(),
        excluded_domains: state
            .excluded_domains
            .lock()
            .map(|domains| domains.clone())
            .unwrap_or_default(),
        llm_provider: llm.provider,
        llm_base_url: llm.base_url,
        llm_model: llm.model,
        llm_api_key_set: llm
            .api_key
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
        ui_language: state
            .languages
            .lock()
            .map_or_else(|_| default_language(), |langs| langs.0.clone()),
        summary_language: state
            .languages
            .lock()
            .map_or_else(|_| default_language(), |langs| langs.1.clone()),
        language_options: afterray_protocol::summary_language_options(),
        model_download_endpoint: state
            .model_download_endpoint
            .lock()
            .map(|endpoint| endpoint.clone())
            .unwrap_or_default(),
        cli_evidence_until_ms: cli_evidence_until_ms(state),
    }
}

/// The slot length currently in force, in whole minutes. Rounded up so a
/// geometry the daemon cannot name still renders as *something* in the picker
/// rather than as `0`.
fn summary_slot_minutes(state: &AppState) -> u32 {
    u32::try_from(state.store.summary_slot_duration_ms().div_euclid(60_000))
        .unwrap_or(afterray_protocol::DEFAULT_SUMMARY_SLOT_MINUTES)
        .max(1)
}

fn persist_current_settings(state: &AppState) -> std::io::Result<()> {
    save_persisted_settings(&state.data_dir, &persisted_settings(state))
}

// @dec:hf-mirror-failover — docs/decisions/active/product/2026-08-20-hf-mirror-failover.md
fn persist_adopted_huggingface_mirror(state: &AppState) {
    let stored = state
        .model_download_endpoint
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    let Some(mirror) = huggingface_mirror_to_persist(&stored) else {
        return;
    };
    {
        let mut endpoint = state
            .model_download_endpoint
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        endpoint.clone_from(&mirror);
    }
    if let Err(error) = persist_current_settings(state) {
        eprintln!("could not save the download origin after switching to the mirror: {error}");
    }
}

/// Disk first, then memory. A failed write must not leave the live window
/// open (or closed) against a settings.json that still has the old value.
fn persist_then_store_cli_evidence(
    data_dir: &Path,
    mut pending: PersistedSettings,
    slot: &std::sync::Mutex<Option<i64>>,
    until: Option<i64>,
) -> std::io::Result<()> {
    pending.cli_evidence_until_ms = until;
    save_persisted_settings(data_dir, &pending)?;
    *slot
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = pending.cli_evidence_until_ms;
    Ok(())
}

fn persisted_settings(state: &AppState) -> PersistedSettings {
    let llm = current_llm_config(state);
    PersistedSettings {
        record_audio: state.capture.record_audio(),
        storage_limit_bytes: state.store.storage_limit_bytes(),
        excluded_bundle_ids: state
            .excluded_bundle_ids
            .lock()
            .map(|ids| ids.clone())
            .unwrap_or_default(),
        excluded_domains: state
            .excluded_domains
            .lock()
            .map(|domains| domains.clone())
            .unwrap_or_default(),
        llm_provider: llm.provider,
        llm_base_url: llm.base_url,
        llm_model: llm.model,
        // The key itself lives in the Keychain; this file never carries it.
        legacy_llm_api_key: String::new(),
        ui_language: state
            .languages
            .lock()
            .map_or_else(|_| default_language(), |langs| langs.0.clone()),
        summary_language: state
            .languages
            .lock()
            .map_or_else(|_| default_language(), |langs| langs.1.clone()),
        model_download_endpoint: state
            .model_download_endpoint
            .lock()
            .map(|endpoint| endpoint.clone())
            .unwrap_or_default(),
        compute_mode: state.compute.mode(),
        compute_paused_until_ms: state.compute.persisted_pause_ms(),
        cli_evidence_until_ms: cli_evidence_until_ms(state),
    }
}

/// Every field a settings update may carry. Grouped so the handler keeps
/// one parameter as the surface grows.
struct SettingsPatch {
    record_audio: Option<bool>,
    ui_language: Option<String>,
    summary_language: Option<String>,
    storage_limit_bytes: Option<u64>,
    summary_slot_minutes: Option<u32>,
    excluded_bundle_ids: Option<Vec<String>>,
    excluded_domains: Option<Vec<String>>,
    llm_provider: Option<LlmProvider>,
    llm_base_url: Option<String>,
    llm_model: Option<String>,
    llm_api_key: Option<String>,
    model_download_endpoint: Option<String>,
    cli_evidence_access: Option<bool>,
}

async fn update_settings(state: &Arc<AppState>, patch: SettingsPatch) -> Response {
    let SettingsPatch {
        record_audio,
        ui_language,
        summary_language,
        storage_limit_bytes,
        summary_slot_minutes,
        excluded_bundle_ids,
        excluded_domains,
        llm_provider,
        llm_base_url,
        llm_model,
        llm_api_key,
        model_download_endpoint,
        cli_evidence_access,
    } = patch;
    if let Some(enabled) = cli_evidence_access {
        let until = enabled.then(|| now_ms().saturating_add(CLI_EVIDENCE_WINDOW_MS));
        if let Err(error) = persist_then_store_cli_evidence(
            &state.data_dir,
            persisted_settings(state),
            &state.cli_evidence_until_ms,
            until,
        ) {
            return Response::failure(format!("could not save CLI evidence access: {error}"));
        }
    }
    if let Some(endpoint) = model_download_endpoint {
        let cleaned = endpoint.trim().trim_end_matches('/').to_owned();
        // Same origin policy as the LLM endpoint: https, or plain http only to
        // this machine. Pinned packs are hash-verified regardless, but the asr
        // and embedding downloads carry `HF_TOKEN` if one is set.
        if !cleaned.is_empty()
            && let Err(error) = afterray_models::check_origin(&cleaned)
        {
            return Response::failure(error);
        }
        {
            let mut endpoint = state
                .model_download_endpoint
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            endpoint.clone_from(&cleaned);
        }
        afterray_models::set_huggingface_endpoint(Some(cleaned));
        if let Err(error) = persist_current_settings(state) {
            return Response::failure(format!("could not save the download endpoint: {error}"));
        }
    }
    if ui_language.is_some() || summary_language.is_some() {
        let mut pending = persisted_settings(state);
        if let Some(value) = ui_language.clone() {
            pending.ui_language = value;
        }
        if let Some(value) = summary_language.clone() {
            pending.summary_language = value;
        }
        if let Ok(mut langs) = state.languages.lock() {
            langs.0 = pending.ui_language.clone();
            langs.1 = pending.summary_language.clone();
        }
        let _ = save_persisted_settings(&state.data_dir, &pending);
    }
    if let Some(bytes) = storage_limit_bytes {
        let previous = state.store.storage_limit_bytes();
        let mut pending = persisted_settings(state);
        pending.storage_limit_bytes = bytes;
        if let Err(error) = save_persisted_settings(&state.data_dir, &pending) {
            return Response::failure(format!("could not save storage limit: {error}"));
        }
        if let Err(error) = state.store.set_storage_limit_bytes(bytes) {
            let mut rollback = persisted_settings(state);
            rollback.storage_limit_bytes = previous;
            let _ = save_persisted_settings(&state.data_dir, &rollback);
            return Response::failure(format!("could not apply storage limit: {error}"));
        }
    }
    if let Some(minutes) = summary_slot_minutes {
        let duration_ms = i64::from(minutes).saturating_mul(60_000);
        let store = Arc::clone(state);
        let applied = tokio::task::spawn_blocking(move || {
            store
                .store
                .set_summary_slot_duration_ms(duration_ms, now_ms())
        })
        .await;
        match applied {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                return Response::failure(format!("could not change the summary length: {error}"));
            }
            Err(error) => {
                return Response::failure(format!("could not change the summary length: {error}"));
            }
        }
    }
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
        push_audio_exclusions(state).await;
        if let Err(error) = persist_current_settings(state) {
            return Response::failure(format!("could not save settings: {error}"));
        }
    }
    if let Some(domains) = excluded_domains {
        let cleaned = normalize_domains(domains);
        {
            let mut excluded = state
                .excluded_domains
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
        // Validate and persist the credential before touching live config, so
        // a rejected endpoint or a Keychain failure leaves the assistant
        // exactly as the user last confirmed it.
        if let Some(base_url) = llm_base_url.as_deref().map(str::trim)
            && !base_url.is_empty()
            && let Err(error) = afterray_models::check_origin(base_url)
        {
            return Response::failure(error);
        }
        if let Some(api_key) = llm_api_key.as_deref().map(str::trim) {
            let stored = if api_key.is_empty() {
                afterray_store::delete_secret(LLM_API_KEY_SECRET)
            } else {
                afterray_store::store_secret(LLM_API_KEY_SECRET, api_key)
            };
            if let Err(error) = stored {
                return Response::failure(format!(
                    "could not save the assistant API key to the Keychain: {error}"
                ));
            }
        }
        let previous_llm = current_llm_config(state);
        let previous_mlx_pack = (previous_llm.provider == LlmProvider::MlxLocal)
            .then(|| previous_llm.mlx_pack_id().map(ToOwned::to_owned))
            .flatten();
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
        let selected_llm = current_llm_config(state);
        let selected_mlx_pack = (selected_llm.provider == LlmProvider::MlxLocal)
            .then(|| selected_llm.mlx_pack_id().map(ToOwned::to_owned))
            .flatten();
        if previous_mlx_pack != selected_mlx_pack
            && let Some(previous_mlx_pack) = previous_mlx_pack
            && let Some((_, adapter)) = state
                .mlx_adapters
                .iter()
                .find(|(pack_id, _)| pack_id == &previous_mlx_pack)
        {
            adapter.shutdown().await;
        }
    }
    Response::success(current_settings(state))
}

fn resolve_llm_config(persisted: &PersistedSettings) -> LlmRuntimeConfig {
    let mut config = LlmRuntimeConfig {
        provider: std::env::var("AFTERRAY_LLM_PROVIDER")
            .ok()
            .as_deref()
            .and_then(LlmProvider::parse)
            .unwrap_or(persisted.llm_provider),
        base_url: env_nonempty("AFTERRAY_LLM_BASE_URL")
            .unwrap_or_else(|| persisted.llm_base_url.clone()),
        model: env_nonempty("AFTERRAY_LLM_CHAT_MODEL")
            .unwrap_or_else(|| persisted.llm_model.clone()),
        api_key: env_nonempty("AFTERRAY_LLM_API_KEY")
            .or_else(stored_api_key)
            // Only reachable when the Keychain refused the migration write.
            .or_else(|| {
                let key = persisted.legacy_llm_api_key.trim();
                (!key.is_empty()).then(|| key.to_owned())
            }),
        context_tokens: None,
    };
    // Settings carried over from the retired built-in provider can hold a
    // remote chat model id, which is not a managed MLX pack. Drop it so the
    // local path falls back to the recommended 4B instead of refusing to run.
    if config.provider == LlmProvider::MlxLocal && config.mlx_pack_id().is_none() {
        config.model.clear();
    }
    config
}

fn stored_api_key() -> Option<String> {
    match afterray_store::load_secret(LLM_API_KEY_SECRET) {
        Ok(value) => value
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty()),
        Err(error) => {
            eprintln!("could not read the assistant API key from the Keychain: {error}");
            None
        }
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
        .filter(|id| !id.is_empty() && !is_protected_bundle(id))
        .collect::<Vec<_>>();
    cleaned.sort();
    cleaned.dedup();
    cleaned
}

/// Password managers and system credential surfaces are not ordinary user
/// exclusions. They are always blocked at the daemon boundary so an older UI,
/// a hand-edited settings file, or an accidental remove action cannot expose
/// vault contents to screenshots, OCR, or accessibility capture.
const PROTECTED_BUNDLE_IDS: &[&str] = &[
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.apple.Passwords",
    "com.apple.keychainaccess",
    "com.apple.loginwindow",
    "com.bitwarden.desktop",
    "com.callpod.keepermac.lite",
    "com.dashlane.Dashlane",
    "com.keepassium.intune",
    "com.keepassium.ios",
    "com.keepassium.ios.pro",
    "com.keepersecurity.passwordmanager",
    "com.lastpass.LastPass",
    "com.lastpass.lastpassforsafari",
    "com.markmcguill.strongbox",
    "com.markmcguill.strongbox.mac.pro",
    "com.markmcguill.strongbox.pro",
    "com.nordsec.nordpass",
    "com.siber.roboform",
    "com.sibersystems.RoboForm",
    "dev.afterray.app",
    "in.sinew.Enpass-Desktop",
    "me.proton.pass.electron",
    "org.keepassxc.keepassxc",
];

fn protected_bundle_ids() -> Vec<String> {
    PROTECTED_BUNDLE_IDS
        .iter()
        .map(|id| (*id).to_owned())
        .collect()
}

fn default_excluded_bundle_ids() -> Vec<String> {
    normalize_bundle_ids(Vec::new())
}

fn is_protected_bundle(bundle_id: &str) -> bool {
    PROTECTED_BUNDLE_IDS
        .iter()
        .any(|protected| protected.eq_ignore_ascii_case(bundle_id))
}

/// Hands the capture helper the same set [`is_excluded_bundle`] enforces, so
/// it can keep an excluded app's audio off disk while it is frontmost.
///
/// Screen exclusions stay here — only the accessibility snapshot carries a URL,
/// and a moment can be deleted after the fact. A finished audio segment covers
/// five minutes that cannot be sliced apart, so audio has to be dropped before
/// it is written.
async fn push_audio_exclusions(state: &Arc<AppState>) {
    let mut bundle_ids = protected_bundle_ids();
    bundle_ids.extend(
        state
            .excluded_bundle_ids
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .iter()
            .cloned(),
    );
    bundle_ids.sort();
    bundle_ids.dedup();
    if let Err(error) = state.capture.set_excluded_bundle_ids(bundle_ids).await {
        eprintln!("could not send the audio exclusion list to the capture helper: {error}");
    }
}

fn is_excluded_bundle(state: &AppState, bundle_id: Option<&str>) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    if is_protected_bundle(bundle_id) {
        return true;
    }
    state
        .excluded_bundle_ids
        .lock()
        .map(|ids| ids.iter().any(|id| id.eq_ignore_ascii_case(bundle_id)))
        .unwrap_or(false)
}

/// The host part of whatever the user typed. People paste a full URL as often
/// as they type a bare host, and asking them to know the difference is a way
/// to get an exclusion that silently never matches.
fn normalize_domain(input: &str) -> Option<String> {
    let trimmed = input.trim().trim_matches('/');
    let without_scheme = trimmed.split_once("://").map_or(trimmed, |(_, rest)| rest);
    // Drop userinfo, then path/query/fragment, then port.
    let after_userinfo = without_scheme
        .rsplit_once('@')
        .map_or(without_scheme, |(_, rest)| rest);
    let host = after_userinfo
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default()
        .rsplit_once(':')
        // An IPv6 literal has colons of its own; only strip a numeric port.
        .filter(|(_, port)| !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()))
        .map_or(
            after_userinfo
                .split(['/', '?', '#'])
                .next()
                .unwrap_or_default(),
            |(head, _)| head,
        );
    let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() || !host.contains('.') {
        return None;
    }
    Some(host)
}

fn normalize_domains(inputs: Vec<String>) -> Vec<String> {
    let mut cleaned = inputs
        .iter()
        .filter_map(|input| normalize_domain(input))
        .collect::<Vec<_>>();
    cleaned.sort();
    cleaned.dedup();
    cleaned
}

/// Subdomains are covered: excluding `example.com` has to stop
/// `mail.example.com` too, or the exclusion is a false promise. It must not
/// stop `notexample.com`, which is a different site entirely.
fn host_matches_domain(host: &str, domain: &str) -> bool {
    host == domain
        || host
            .strip_suffix(domain)
            .is_some_and(|prefix| prefix.ends_with('.'))
}

fn is_excluded_url(state: &AppState, url: Option<&str>) -> bool {
    let Some(host) = url.and_then(normalize_domain) else {
        return false;
    };
    state
        .excluded_domains
        .lock()
        .map(|domains| {
            domains
                .iter()
                .any(|domain| host_matches_domain(&host, domain))
        })
        .unwrap_or(false)
}

async fn clear_history(state: &Arc<AppState>, scope: HistoryScope) -> Response {
    let now = now_ms();
    let (from_ms, to_ms) = match scope {
        HistoryScope::LastHour => (now.saturating_sub(60 * 60 * 1000), now),
        HistoryScope::Today => local_calendar_day_bounds_ms(now),
        HistoryScope::All => (0, now),
    };
    run_store(state, move |s| {
        memory::flush(&s.store, &s.memories);
        match s.store.delete_history(from_ms, to_ms) {
            Ok(deleted) => Response::success(serde_json::json!({
                "scope": scope,
                "deleted": deleted,
                "from_ms": from_ms,
                "to_ms": to_ms,
            })),
            Err(error) => Response::failure(error.to_string()),
        }
    })
    .await
}

fn settings_path(data_dir: &Path) -> PathBuf {
    data_dir.join("settings.json")
}

fn load_persisted_settings(data_dir: &Path) -> PersistedSettings {
    let Ok(text) = std::fs::read_to_string(settings_path(data_dir)) else {
        return PersistedSettings::default();
    };
    let mut settings = serde_json::from_str::<PersistedSettings>(&text).unwrap_or_default();
    // Older builds copied the complete protected catalogue into this user
    // preference. Strip those seeded entries: protection is enforced directly
    // by `is_excluded_bundle`, while the UI shows only apps installed locally.
    settings.excluded_bundle_ids = normalize_bundle_ids(settings.excluded_bundle_ids);
    settings
}

/// Written `0600` through a temporary file, the way the vault writes its own
/// artifacts. A plain `std::fs::write` took the process umask, so this file —
/// which carries the exclusion lists and, before the key moved to the
/// Keychain, the API key — landed `0644` beside the encrypted vault.
fn save_persisted_settings(data_dir: &Path, settings: &PersistedSettings) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};

    std::fs::create_dir_all(data_dir)?;
    std::fs::set_permissions(data_dir, std::fs::Permissions::from_mode(0o700))?;
    let path = settings_path(data_dir);
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(settings)?;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&temporary, &path)?;
    // An upgrade inherits whatever mode the old writer left behind.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// V0 wrote the OpenAI-compatible API key in cleartext into `settings.json`.
/// Move any such key into the Keychain on the first launch that can, and
/// rewrite the file without it.
fn migrate_api_key_to_keychain(
    data_dir: &Path,
    mut persisted: PersistedSettings,
) -> PersistedSettings {
    let legacy = std::mem::take(&mut persisted.legacy_llm_api_key);
    let legacy = legacy.trim();
    if legacy.is_empty() {
        return persisted;
    }
    if let Err(error) = afterray_store::store_secret(LLM_API_KEY_SECRET, legacy) {
        // Keep the key working this session rather than silently signing the
        // user out of their own assistant; the file stays as it was.
        eprintln!("could not move the assistant API key into the Keychain: {error}");
        persisted.legacy_llm_api_key = legacy.to_owned();
        return persisted;
    }
    if let Err(error) = save_persisted_settings(data_dir, &persisted) {
        eprintln!("could not rewrite settings.json without the API key: {error}");
    }
    persisted
}

async fn record_stop(state: &Arc<AppState>, reason: Option<&str>) -> Response {
    let is_shutdown = reason == Some("shutdown");
    let _capture_lifecycle = if is_shutdown {
        None
    } else {
        Some(state.capture_lifecycle.enter().await)
    };
    let stop_started = Instant::now();
    let reason = reason.unwrap_or("pause").to_owned();
    let (session_id, scheduler, consumer) = {
        let mut recording = state.recording.lock().await;
        let Some(session_id) = recording.active_session_id.take() else {
            let _ = run_store(state, move |s| {
                memory::flush(&s.store, &s.memories);
                s.store.begin_idle_span(now_ms(), &reason)
            })
            .await;
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
    let capture_started = Instant::now();
    let capture_error = state.capture.stop_capture().await.err();
    if is_shutdown {
        eprintln!(
            "shutdown: capture helper stop completed in {} ms ({})",
            capture_started.elapsed().as_millis(),
            if capture_error.is_some() {
                "forced/error"
            } else {
                "graceful"
            }
        );
    }
    let memory_flush = run_store(state, move |s| {
        memory::flush(&s.store, &s.memories);
        s.store.begin_idle_span(now_ms(), &reason)
    });
    let session_for_store = session_id.clone();
    let session_close = run_store(state, move |s| {
        s.store.end_session_sync(&session_for_store, now_ms())
    });
    // A graceful helper emitted a finite stream ending in `Stopped`. Every
    // final artifact ahead of it must finish importing before memory flush and
    // session close. None of this required durability seam has a daemon-local
    // timeout; only a helper already known to have failed gets the 250 ms
    // consumer recovery cap.
    let (consumer_error, _, store_result) = finish_recording_after_helper_stop(
        consumer,
        capture_error.is_some(),
        if is_shutdown {
            "shutdown"
        } else {
            "record_stop"
        },
        memory_flush,
        session_close,
    )
    .await;
    let discarded = state.capture.discard_stopped_generation_events().await;
    if discarded > 0 {
        eprintln!("record_stop: discarded {discarded} stale generation event(s)");
    }
    if is_shutdown {
        eprintln!(
            "shutdown: capture/session close completed in {} ms",
            stop_started.elapsed().as_millis()
        );
    }
    let capture_error = match (capture_error, consumer_error) {
        (Some(error), Some(consumer_error)) => Some(format!("{error}; {consumer_error}")),
        (Some(error), None) => Some(error.to_string()),
        (None, Some(consumer_error)) => Some(consumer_error),
        (None, None) => None,
    };
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

/// Marks a stretch as unobservable rather than empty.
///
/// The two fact streams are read very differently when one goes quiet: a slot
/// with no frames is obviously a hole, but a slot with no input events looks
/// exactly like a slot where the user sat and read. Whenever the daemon knows
/// it *lost* observations — the tap died, or a batch failed to land — it says
/// so in the stream itself, and the join downgrades that stretch to
/// `unavailable` instead of asserting an engaged scope over it.
///
/// Best effort by construction: if this write fails too there is nothing
/// further to say, and stalling capture over it would trade frames for
/// bookkeeping.
async fn record_signal_gap(state: &Arc<AppState>, from_ms: i64, to_ms: i64, reason: &str) {
    let marker = InputEventRow {
        at_ms: from_ms,
        end_ms: (to_ms > from_ms).then_some(to_ms),
        kind: afterray_store::acts::SIGNAL_GAP_KIND.to_owned(),
        count: None,
        ended_with: None,
        command: Some(reason.to_owned()),
        bundle_identifier: None,
        target_json: None,
        text: None,
        extra_json: None,
    };
    if let Err(error) = run_store(state, move |s| s.store.insert_input_events(&[marker])).await {
        eprintln!("input signal gap store failed: {error}");
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureStreamDisposition {
    Continue,
    Stopped,
    Failed,
}

fn capture_stream_disposition(
    event: &Result<CaptureEvent, CaptureError>,
) -> CaptureStreamDisposition {
    match event {
        Ok(CaptureEvent::Stopped) => CaptureStreamDisposition::Stopped,
        Ok(CaptureEvent::Failed { .. }) | Err(_) => CaptureStreamDisposition::Failed,
        Ok(_) => CaptureStreamDisposition::Continue,
    }
}

/// Reads the capture stream in protocol order and does not observe `Stopped`
/// until the handler for every earlier event has completed.
async fn consume_capture_event_stream<N, NFuture, H, HFuture, F, FFuture>(
    mut next_event: N,
    mut handle_event: H,
    mut finish_failed: F,
) -> CaptureConsumerOutcome
where
    N: FnMut() -> NFuture,
    NFuture: std::future::Future<Output = Option<Result<CaptureEvent, CaptureError>>>,
    H: FnMut(CaptureEvent) -> HFuture,
    HFuture: std::future::Future<Output = ()>,
    F: FnMut() -> FFuture,
    FFuture: std::future::Future<Output = ()>,
{
    loop {
        let Some(event) = next_event().await else {
            let error = "capture event stream ended before stopped".to_owned();
            eprintln!("{error}");
            finish_failed().await;
            return CaptureConsumerOutcome::Failed(error);
        };
        match capture_stream_disposition(&event) {
            CaptureStreamDisposition::Stopped => return CaptureConsumerOutcome::Stopped,
            CaptureStreamDisposition::Failed => {
                let error = match &event {
                    Ok(CaptureEvent::Failed { code, message }) => {
                        eprintln!("capture failed [{code}]: {message}");
                        format!("capture failed [{code}]: {message}")
                    }
                    Err(error) => {
                        eprintln!("capture event stream failed: {error}");
                        error.to_string()
                    }
                    Ok(_) => unreachable!("failed disposition requires a terminal failure"),
                };
                finish_failed().await;
                return CaptureConsumerOutcome::Failed(error);
            }
            CaptureStreamDisposition::Continue => {}
        }

        handle_event(event.expect("continued capture event must be successful")).await;
    }
}

async fn handle_capture_event(state: &Arc<AppState>, session_id: &str, event: CaptureEvent) {
    match event {
        // The startup handshake already recorded this, but the shim may
        // re-announce after a display change, and the OCR crop is only as
        // good as the dimensions it maps against.
        CaptureEvent::Ready { width, height, .. } => {
            remember_capture_display(state, width, height);
        }
        CaptureEvent::Artifact {
            kind,
            path,
            content_type,
            started_at_ms,
            ended_at_ms,
            ..
        } => {
            let result = import_artifact(
                state,
                session_id,
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
        CaptureEvent::Warning { code, message } => {
            eprintln!("capture warning [{code}]: {message}");
            // A dead input tap is a hole in one of the two fact streams,
            // and it has to be recorded *in* that stream: T1 reads the
            // absence of events as "the user did nothing here", which is
            // exactly the inference this pipeline exists to prevent. The
            // marker rides the same table (the vault stores `kind`
            // uninterpreted) so the gap arrives in its place in time.
            if matches!(code.as_str(), "input_tap_stalled" | "input_tap_unavailable") {
                let at = now_ms();
                record_signal_gap(state, at, at, &code).await;
            }
        }
        CaptureEvent::InputEvents { events, dropped } => {
            if !events.is_empty() || dropped > 0 {
                eprintln!(
                    "capture input events batch={} dropped={dropped}",
                    events.len()
                );
            }
            if !events.is_empty() {
                let rows: Vec<InputEventRow> = events.iter().map(input_event_row).collect();
                let span = rows
                    .first()
                    .map(|first| (first.at_ms, rows.last().map_or(first.at_ms, |l| l.at_ms)));
                // A failed batch is not retried: the events are one of two
                // independent fact streams, and stalling capture over the
                // softer one would cost frames. But it must not vanish
                // quietly either — a stretch with no rows reads as "the
                // user did nothing", which is the one thing this pipeline
                // may never say by accident. Mark the stretch unobservable
                // instead, the same way a dead tap is marked.
                if let Err(error) =
                    run_store(state, move |s| s.store.insert_input_events(&rows)).await
                {
                    eprintln!("capture input events store failed: {error}");
                    if let Some((from_ms, to_ms)) = span {
                        record_signal_gap(state, from_ms, to_ms, "input_events_store_failed").await;
                    }
                }
            }
            // The user did something; the heartbeat's next tick may be nine
            // seconds away. Pull the frame forward so the screenshot lands
            // near the interaction rather than wherever the timer's phase
            // happened to fall — the cadence stays the same, its phase
            // stops being arbitrary. A failed store above does not change
            // this: the frame is worth having either way.
            if event_capture_is_due(
                events.len(),
                state.last_capture_ms.load(Ordering::SeqCst),
                now_ms(),
                i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000),
            ) {
                fire_capture_tick(state).await;
            }
        }
        CaptureEvent::Failed { .. } | CaptureEvent::Stopped => {
            unreachable!("terminal capture events are handled before import")
        }
    }
}

async fn consume_capture_events(
    state: Arc<AppState>,
    session_id: String,
) -> CaptureConsumerOutcome {
    let capture = Arc::clone(&state.capture);
    let event_state = Arc::clone(&state);
    let event_session_id = session_id.clone();
    let failed_state = Arc::clone(&state);
    consume_capture_event_stream(
        move || {
            let capture = Arc::clone(&capture);
            async move { capture.next_event().await }
        },
        move |event| {
            let state = Arc::clone(&event_state);
            let session_id = event_session_id.clone();
            async move { handle_capture_event(&state, &session_id, event).await }
        },
        move || {
            let state = Arc::clone(&failed_state);
            let session_id = session_id.clone();
            async move { finish_failed_recording(&state, &session_id).await }
        },
    )
    .await
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
    let session_id = session_id.to_owned();
    let _ = run_store(state, move |s| {
        s.store.end_session_sync(&session_id, now_ms())
    })
    .await;
}

/// Maps one shim observation onto its vault row.
///
/// `target` is stored as the platform layer's own JSON. The vault does not
/// interpret element identities and this phase does not either; the T1 join is
/// the first reader that will. A target that somehow cannot be encoded is
/// stored as absent rather than dropping the event — that an input happened is
/// the load-bearing fact; where it landed is the refinement.
/// The shim's record as the vault holds it.
///
/// Every field the shim sends lands somewhere: the ones readers filter on have
/// columns, `target` and the rest are serialised verbatim. The store models
/// none of it — a `kind` or a field this build has never heard of must still
/// round-trip, because the shim can ship ahead of its reader.
fn input_event_row(record: &InputEventRecord) -> InputEventRow {
    InputEventRow {
        at_ms: record.at_ms,
        end_ms: record.end_ms,
        kind: record.kind.clone(),
        count: record.count,
        ended_with: record.ended_with.clone(),
        command: record.command.clone(),
        bundle_identifier: record.bundle_identifier.clone(),
        target_json: record
            .target
            .as_ref()
            .and_then(|target| serde_json::to_string(target).ok()),
        text: record.text.clone(),
        extra_json: input_event_extra_json(record),
    }
}

/// The record fields with no column of their own, as one JSON object holding
/// only the keys that are present.
///
/// Absent stays absent rather than becoming `null`: these fields are per-kind
/// (`application_name`/`window_title` on `window_changed`, `source`/
/// `destination` on `drag`), so on any given row most of them are missing by
/// definition, and a row of nulls would be four times the bytes at interaction
/// rate. An object with no keys at all is stored as SQL `NULL` for the same
/// reason — `{}` and "nothing to say" are the same fact.
fn input_event_extra_json(record: &InputEventRecord) -> Option<String> {
    let mut extra = serde_json::Map::new();
    for (key, held) in [
        ("application_name", record.application_name.as_ref()),
        ("window_title", record.window_title.as_ref()),
    ] {
        if let Some(held) = held {
            extra.insert(key.to_owned(), serde_json::Value::String(held.clone()));
        }
    }
    for (key, held) in [
        ("source", record.source.as_ref()),
        ("destination", record.destination.as_ref()),
    ] {
        if let Some(held) = held
            && let Ok(value) = serde_json::to_value(held)
        {
            extra.insert(key.to_owned(), value);
        }
    }
    if extra.is_empty() {
        return None;
    }
    serde_json::to_string(&serde_json::Value::Object(extra)).ok()
}

/// Records the captured display's logical size, the only geometry the daemon
/// ever learns about a screenshot.
///
/// A size that cannot be used is stored as `None` rather than as a guess: the
/// OCR crop reads that as "do not crop" and keeps every region.
fn remember_capture_display(state: &Arc<AppState>, width: usize, height: usize) {
    let display = ocr_crop::DisplayPoints::new(width, height);
    if display.is_none() {
        eprintln!(
            "capture runtime: shim reported a {width}x{height} display; OCR window cropping stays off"
        );
    }
    *state.capture_display.lock().unwrap() = display;
}

/// Narrows a frame's OCR to the frontmost window, dropping the menu bar,
/// desktop widgets and clipped background windows that share the screenshot.
///
/// Returns the text and regions to store. Every uncertainty keeps the worker's
/// output verbatim (`docs/event-capture-v2-plan.md` §7): the accessibility
/// snapshot is read back from the moment because it is attached *after* the
/// screenshot lands, so a snapshot that has not arrived yet — or one that names
/// no window — simply means no crop, never a partial one.
async fn crop_ocr_to_window(
    state: &Arc<AppState>,
    moment_id: &str,
    text: String,
    regions: Vec<OcrRegion>,
) -> (String, Vec<OcrRegion>) {
    let display = *state.capture_display.lock().unwrap();
    if regions.is_empty() || display.is_none() {
        return (text, regions);
    }
    let wanted = moment_id.to_owned();
    let snapshot = run_store(state, move |s| {
        s.store
            .accessibility_bytes_for_moment(&wanted)
            .ok()
            .flatten()
    })
    .await;
    let window = snapshot
        .as_deref()
        .and_then(ocr_crop::frontmost_window_frame);
    let cropped = ocr_crop::crop_to_window(regions, window, display);
    if cropped.dropped == 0 {
        return (text, cropped.regions);
    }
    eprintln!(
        "ocr window crop: kept {} regions, dropped {}, moment {moment_id}",
        cropped.regions.len(),
        cropped.dropped
    );
    (ocr_crop::regions_text(&cropped.regions), cropped.regions)
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
            let session_id = session_id.to_owned();
            let content_type = content_type.to_owned();
            let moment = run_store(state, move |s| {
                let moment =
                    s.store
                        .insert_moment(&session_id, started_at_ms, &content_type, &bytes)?;
                Ok::<_, StoreError>(moment)
            })
            .await?;
            {
                let mut recording = state.recording.lock().await;
                if recording.active_session_id.as_deref() == Some(moment.session_id.as_str()) {
                    recording.captured_frame = true;
                }
            }
            // The one gate that only "off" can close. Nothing in the vault
            // remembers that a frame went un-OCR'd, so a skipped frame is never
            // indexed by anything later — which is why an hour-long suspension
            // deliberately leaves screen text running (see compute.rs) and only
            // the explicit switch, whose copy says what it costs, stops it.
            if let Err(refusal) = state.compute.decide(
                afterray_protocol::ComputeWorkload::Ocr,
                compute::MachineConditions::probe(),
                now_ms(),
            ) {
                eprintln!(
                    "screen text skipped for moment {}: {}",
                    moment.id, refusal.reason
                );
                // The staging copy is normally deleted by the OCR task that
                // never runs here. Leaving it would fill the staging directory
                // with plaintext JPEGs for as long as the switch stays off.
                if let Err(error) = tokio::fs::remove_file(path).await {
                    eprintln!(
                        "could not remove capture staging file {}: {error}",
                        path.display()
                    );
                }
                return Ok(());
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
            let task = tokio::spawn(async move {
                let snapshot = model_state.models.wait(&job).await;
                if let Ok(snapshot) = snapshot
                    && let Some(ModelOutput::Ocr { text, regions }) = snapshot.output
                {
                    let (text, regions) =
                        crop_ocr_to_window(&model_state, &moment.id, text, regions).await;
                    let layout_json = if regions.is_empty() {
                        None
                    } else {
                        serde_json::to_string(&regions).ok()
                    };
                    let session_id = moment.session_id.clone();
                    let moment_id = moment.id.clone();
                    let adapter = snapshot.adapter.clone();
                    let text_for_store = text.clone();
                    let evidence = run_store(&model_state, move |s| {
                        s.store.insert_text_evidence(
                            &session_id,
                            Some(&moment_id),
                            None,
                            "ocr",
                            &text_for_store,
                            moment.captured_at_ms,
                            None,
                            &adapter,
                            layout_json.as_deref(),
                        )
                    })
                    .await;
                    // Embeddings are switched off; see `search_hits`. The
                    // text itself is stored, so vectors stay re-derivable
                    // whenever the redesign lands.
                    let _ = evidence;
                }
                let _ = tokio::fs::remove_file(path).await;
            });
            state.lifecycle.track_task(task);
        }
        ArtifactKind::SystemAudio | ArtifactKind::Microphone => {
            let track = match kind {
                ArtifactKind::Microphone => afterray_protocol::AudioTrack::Microphone,
                ArtifactKind::SystemAudio
                | ArtifactKind::Screen
                | ArtifactKind::Accessibility
                | ArtifactKind::AccessibilityEdge => afterray_protocol::AudioTrack::System,
            };
            // Near-silent AAC (idle mic / empty system track) is not speech and
            // is not searchable. Drop it before encryption so overnight desks
            // do not accrue megabytes of room tone.
            if is_near_silent_audio(bytes.len(), started_at_ms, ended_at_ms) {
                if let Err(error) = tokio::fs::remove_file(path).await {
                    eprintln!(
                        "could not remove silent audio staging file {}: {error}",
                        path.display()
                    );
                }
            } else {
                let session_id = session_id.to_owned();
                let content_type = content_type.to_owned();
                run_store(state, move |s| {
                    s.store.insert_audio_segment(
                        &session_id,
                        track,
                        started_at_ms,
                        ended_at_ms,
                        &content_type,
                        &bytes,
                    )
                })
                .await?;
                // The encrypted segment is the durable queue. Plaintext exists
                // again only while the sweeper owns a claimed ASR item.
                if let Err(error) = tokio::fs::remove_file(path).await {
                    eprintln!(
                        "could not remove imported audio staging file {}: {error}",
                        path.display()
                    );
                }
                state.asr_changed.notify_one();
            }
        }
        ArtifactKind::Accessibility => {
            // A snapshot that will not parse names no app, and an unnamed app
            // cannot be checked against the exclusion list. Treat it the way
            // the helper treats a missing snapshot: drop the frame rather than
            // keep one that might belong to an app the user excluded.
            let metadata = match serde_json::from_slice::<AccessibilityMetadata>(&bytes) {
                Ok(metadata) => metadata,
                Err(error) => {
                    eprintln!(
                        "accessibility snapshot did not parse, dropping the frame it describes: {error}"
                    );
                    if let Some(moment_id) =
                        nearest_moment_id_async(state, session_id, started_at_ms).await
                    {
                        delete_excluded_moment(state, &moment_id).await;
                    }
                    tokio::fs::remove_file(path).await?;
                    return Ok(());
                }
            };
            // The URL only exists in this snapshot, so a page on an excluded
            // host is identified here or not at all — the screen JPEG has
            // already landed by now and has to be deleted, not skipped.
            if is_excluded_bundle(state, metadata.bundle_identifier.as_deref())
                || is_excluded_url(state, metadata.url.as_deref())
            {
                if let Some(moment_id) =
                    nearest_moment_id_async(state, session_id, started_at_ms).await
                {
                    delete_excluded_moment(state, &moment_id).await;
                }
                tokio::fs::remove_file(path).await?;
                return Ok(());
            }
            let session_id_owned = session_id.to_owned();
            let content_type = content_type.to_owned();
            let attached = run_store(state, {
                let bytes = bytes.clone();
                move |s| {
                    attach_accessibility_artifact(
                        &s.store,
                        &session_id_owned,
                        started_at_ms,
                        &content_type,
                        &bytes,
                    )
                }
            })
            .await?;
            if attached.is_some() {
                if let Some(moment_id) =
                    nearest_moment_id_async(state, session_id, started_at_ms).await
                {
                    let moment_id = moment_id.clone();
                    let _ = run_store(state, move |s| {
                        memory::observe_and_maybe_commit(
                            &s.store,
                            &s.memories,
                            started_at_ms,
                            &moment_id,
                            &bytes,
                        );
                    })
                    .await;
                }
            } else {
                eprintln!(
                    "accessibility snapshot had no screen moment within the two-second alignment window"
                );
            }
            tokio::fs::remove_file(path).await?;
        }
        ArtifactKind::AccessibilityEdge => {
            // Same exclusion posture as the accessibility branch, and for the
            // same reason: this is a whole window's worth of text, and the app
            // that owns it is named nowhere else. There is no moment to delete
            // alongside it — an edge snapshot is unpaired — so an unjudgeable
            // one is simply never stored.
            let Some((bundle_identifier, url)) = edge_snapshot_identity(&bytes) else {
                eprintln!("edge snapshot did not parse or named no app, dropping it unstored");
                tokio::fs::remove_file(path).await?;
                return Ok(());
            };
            if is_excluded_bundle(state, Some(&bundle_identifier))
                || is_excluded_url(state, url.as_deref())
            {
                tokio::fs::remove_file(path).await?;
                return Ok(());
            }
            // No moment, no thumbnail, no OCR job: an edge snapshot is not a
            // frame of the screen, it is extra tree for the T1 join.
            run_store(state, move |s| {
                s.store.insert_edge_snapshot(started_at_ms, &bytes)
            })
            .await?;
            tokio::fs::remove_file(path).await?;
        }
    }
    Ok(())
}

#[derive(Default, serde::Deserialize)]
struct AccessibilityMetadata {
    application_name: Option<String>,
    bundle_identifier: Option<String>,
    /// Present when the foreground app exposes one — browsers do, via the web
    /// area's `AXURL`. This is the structured address used for activity spans
    /// and website exclusions.
    url: Option<String>,
}

/// The app an R3 edge snapshot belongs to, plus the URL it exposes.
///
/// `None` means "do not store this": unparseable and unnamed are the same answer
/// here, because the exclusion list is keyed by bundle identifier and a snapshot
/// naming no app cannot be checked against it. Stricter than the heartbeat
/// branch, which has a screenshot already on disk and must decide what to delete;
/// an edge snapshot loses nothing by being dropped — the next trigger is one
/// interaction away.
fn edge_snapshot_identity(bytes: &[u8]) -> Option<(String, Option<String>)> {
    let metadata = serde_json::from_slice::<AccessibilityMetadata>(bytes).ok()?;
    Some((metadata.bundle_identifier?, metadata.url))
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

async fn nearest_moment_id_async(
    state: &Arc<AppState>,
    session_id: &str,
    captured_at_ms: i64,
) -> Option<String> {
    let session_id = session_id.to_owned();
    run_store(state, move |s| {
        s.store
            .moments_sync(&session_id)
            .ok()?
            .into_iter()
            .rev()
            .find(|moment| moment.captured_at_ms.abs_diff(captured_at_ms) <= 2_000)
            .map(|moment| moment.id)
    })
    .await
}

/// Removing the frame an exclusion just matched *is* the guarantee, so a
/// failure here is retried once and, if it still fails, said out loud.
///
/// A busy writer is the realistic failure and it clears in milliseconds.
/// Anything that survives the retry has left a frame of an app or site the
/// user asked never to record sitting in the vault, and nothing else in the
/// daemon will ever come back to it.
async fn delete_excluded_moment(state: &Arc<AppState>, moment_id: &str) {
    const RETRY_DELAY: Duration = Duration::from_millis(250);

    let moment_id_owned = moment_id.to_owned();
    let Err(error) = run_store(state, move |s| {
        s.store.delete_moment_and_artifacts(&moment_id_owned)
    })
    .await
    else {
        return;
    };
    eprintln!("excluded moment {moment_id} could not be deleted, retrying once: {error}");
    tokio::time::sleep(RETRY_DELAY).await;

    let moment_id_owned = moment_id.to_owned();
    if let Err(error) = run_store(state, move |s| {
        s.store.delete_moment_and_artifacts(&moment_id_owned)
    })
    .await
    {
        eprintln!("excluded moment {moment_id} survived a retry and is still recorded: {error}");
    }
}

/// The capture interval in milliseconds, which several slot readers need.
fn capture_interval_ms(state: &AppState) -> i64 {
    i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000)
}

/// The durable backlog per workload, as the dashboard shows it.
#[derive(Debug, Clone, Copy, Default)]
struct BacklogCounts {
    summaries: usize,
    archive: usize,
    transcripts: usize,
    /// Moments that still have a JPEG but no screen text. Only frames whose
    /// pixels survive are counted: once a moment is packed into a GOP its JPEG
    /// is gone, so counting those would show a pile nothing can ever drain.
    unindexed: usize,
}

/// How long a backlog count is trusted before it is taken again.
///
/// The panel polls every two seconds, so without a cache the counts would be the
/// dashboard's own dominant cost — and it walks slot cards and `moments` against
/// `text_evidence`. Thirty seconds is chosen against how fast the numbers can
/// actually move: a slot becomes eligible for summarising every ten minutes, and
/// audio arrives in five-minute segments. Pressing "run now" drops the cache, so
/// the effect of the one action that is meant to move these numbers is visible on
/// the next poll rather than up to half a minute later.
const BACKLOG_TTL: Duration = Duration::from_secs(30);

async fn backlog_counts(state: &Arc<AppState>) -> BacklogCounts {
    {
        let cached = state.backlog.lock().await;
        if let Some((taken_at, counts)) = cached.as_ref()
            && taken_at.elapsed() < BACKLOG_TTL
        {
            return *counts;
        }
    }
    let policy = state.packer.config.policy;
    let interval_ms = capture_interval_ms(state);
    let now = now_ms();
    // Both counts are `Vault` reads, so they go through `run_store` together:
    // one `spawn_blocking` hop, and — the part that matters — never a synchronous
    // vault call from a tokio worker. `slots_awaiting_t2` walks up to three days
    // of slot cards, which is exactly the kind of blocking that used to freeze
    // socket accepts.
    let counts = run_store(state, move |s| {
        let summaries = slots_awaiting_t2(&s.store, interval_ms, now, T2_LOOKBACK_DAYS).len();
        s.store
            .compute_backlog(now, &policy)
            .map(|vault| BacklogCounts {
                summaries,
                archive: vault.archive_stills,
                transcripts: vault.transcripts,
                unindexed: vault.unindexed_moments,
            })
    })
    .await;
    let counts = counts.unwrap_or_else(|error| {
        eprintln!("compute: could not count the backlog: {error}");
        BacklogCounts::default()
    });
    *state.backlog.lock().await = Some((std::time::Instant::now(), counts));
    counts
}

/// Everything the dashboard shows, gathered against one instant.
///
/// One RPC rather than a client that aggregates `JobsList`: the panel polls
/// while it is open, and the old surface handed back every job the daemon had
/// ever run, including their model outputs.
async fn compute_status(state: &Arc<AppState>) -> afterray_protocol::ComputeStatusReport {
    use afterray_protocol::{ComputeResidentModel, ComputeTask, ComputeWorkload};

    let conditions = compute::MachineConditions::probe();
    let now = now_ms();
    let activity = state.models.activity().await;

    // Sampled pids, so readings for exited one-shot workers are dropped rather
    // than accumulating for the life of the daemon.
    let mut live_pids = vec![std::process::id()];
    let mut running = Vec::with_capacity(activity.running.len() + 1);
    for job in &activity.running {
        let workload = compute::workload_for_capability(job.capability);
        let pid = state
            .models
            .adapter_for(job.capability)
            .and_then(|adapter| adapter.worker_pid(&job.id));
        let (cpu_percent, footprint_bytes) = match pid {
            Some(pid) => {
                live_pids.push(pid);
                state.compute.sample(pid)
            }
            None => (None, None),
        };
        running.push(ComputeTask {
            id: job.id.clone(),
            workload,
            lane: workload.lane(),
            detail: job.adapter.clone(),
            started_at_ms: job.started_at_ms,
            cpu_percent,
            footprint_bytes,
        });
    }

    // AV1 packing runs on a thread inside this process, so it has no worker pid
    // and would be invisible next to the model jobs — the one workload most
    // likely to be the answer to "why is my Mac slow".
    if state.packer.encode_busy() {
        running.push(ComputeTask {
            id: "gop-packer".to_owned(),
            workload: ComputeWorkload::Archive,
            lane: ComputeWorkload::Archive.lane(),
            detail: "rav1e (in the daemon)".to_owned(),
            started_at_ms: now,
            cpu_percent: None,
            footprint_bytes: None,
        });
    }

    let mut resident_models = Vec::new();
    for (pack_id, adapter) in &state.mlx_adapters {
        let health = adapter.health();
        let Some(pid) = health.pid else {
            continue;
        };
        live_pids.push(pid);
        let (cpu_percent, footprint_bytes) = state.compute.sample(pid);
        resident_models.push(ComputeResidentModel {
            pack_id: pack_id.clone(),
            name: health.runtime.clone().unwrap_or_else(|| pack_id.clone()),
            pid: Some(pid),
            footprint_bytes,
            cpu_percent,
        });
    }

    let recent_summaries = state.compute.recent_summaries();
    let machine = state.compute.machine_report(conditions);
    let backlog = backlog_counts(state).await;
    let mut counts = compute::WorkloadCounts::default();
    counts.set(
        ComputeWorkload::Ocr,
        activity.pending_for(ModelCapability::Ocr),
        backlog.unindexed,
    );
    counts.set(
        ComputeWorkload::Asr,
        activity.pending_for(ModelCapability::Asr),
        backlog.transcripts,
    );
    // Embeddings follow whatever OCR and ASR produce; no pile of their own.
    counts.set(
        ComputeWorkload::Embedding,
        activity.pending_for(ModelCapability::Embedding),
        0,
    );
    counts.set(
        ComputeWorkload::Summary,
        activity.pending_for(ModelCapability::Llm),
        backlog.summaries,
    );
    // The packer's backlog lives in the vault, not in the queue.
    counts.set(ComputeWorkload::Archive, 0, backlog.archive);
    let gates = state.compute.gates(conditions, now, &counts);
    state.compute.forget_dead_samples(&live_pids);

    afterray_protocol::ComputeStatusReport {
        mode: state.compute.mode(),
        paused_until_ms: state.compute.paused_until_ms(now),
        running,
        gates,
        machine,
        thresholds: compute::ComputeGovernor::thresholds(),
        resident_models,
        summary_typical_ms: afterray_protocol::typical_run_ms(&recent_summaries),
        recent_summaries,
        capture_paused: state.capture_paused.load(Ordering::SeqCst),
    }
}

/// Fills the governor's duration window from persisted history.
///
/// Read once, at startup: it answers "how long do summaries usually take"
/// immediately after a restart — the moment a user who just updated the app may
/// be wondering why their fans are up — and there is no index behind the query,
/// so it must never reach the dashboard's polling path.
fn seed_summary_history(store: &Vault, compute: &compute::ComputeGovernor) {
    match store.recent_summary_runs(compute::SUMMARY_HISTORY) {
        Ok(runs) => {
            let count = runs.len();
            compute.seed_summaries(runs.into_iter().map(|run| afterray_protocol::ComputeRun {
                slot_start_ms: run.slot_start_ms,
                finished_at_ms: run.produced_at_ms,
                duration_ms: run.latency_ms,
                ok: true,
            }));
            if let Some(typical) = afterray_protocol::typical_run_ms(&compute.recent_summaries()) {
                eprintln!(
                    "compute: {count} past summary duration(s), typically {}",
                    human_duration(Duration::from_millis(
                        u64::try_from(typical).unwrap_or_default()
                    ))
                );
            }
        }
        Err(error) => eprintln!("compute: could not read past summary durations: {error}"),
    }
}

/// A duration a person can read out loud, for log lines. `2m 41s`, not
/// `161337ms`: the log is where someone goes to answer "how long did that
/// take", and milliseconds make them do arithmetic.
fn human_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    if seconds < 60 {
        return format!("{seconds}s");
    }
    if seconds < 3_600 {
        return format!("{}m {:02}s", seconds / 60, seconds % 60);
    }
    format!("{}h {:02}m", seconds / 3_600, (seconds % 3_600) / 60)
}

/// What the recall UI searches with: exact text, and nothing else.
///
/// A person typing into the search field is looking for words they remember
/// seeing, and expects to be shown where those words are. Semantic neighbours
/// cannot answer that — the frame they point at has no matching pixels to
/// highlight — so they are not offered here. Agents get them, under a floor,
/// through [`search_hits`].
pub(crate) fn text_hits(
    store: &Vault,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>, StoreError> {
    store.search(query, limit)
}

/// What the agent searches with.
///
/// Exact text only. This used to fuse in semantic neighbours, and that path is
/// switched off: `Vault::semantic_search` has no vector index — it reads every
/// stored vector out of `SQLite` as JSON and scores it in Rust, which measures
/// 683 ms over one week of capture and grows linearly from there. See the
/// embedding redesign before turning it back on.
///
/// `filter` is applied **in SQL**, before ranking. Taking the best matches in
/// the vault and then dropping the ones outside the range answers a different
/// question than the caller asked, and answers it with silence: a term used
/// often enough to fill the ranking with recent hits made older ones
/// unreachable.
pub(crate) fn search_hits(
    store: afterray_store::ReadOnlyVault<'_>,
    query: &str,
    filter: &afterray_store::SearchFilter,
    limit: usize,
) -> Result<Vec<SearchHit>, StoreError> {
    store.search_filtered(query, filter, limit)
}

/// Runs the T2 pass: T1 card → configured model → parsed card.
///
/// Goes through `ModelQueue` like every other inference, so the builtin
/// GGUF worker, Ollama and any OpenAI-compatible endpoint are all reachable
/// by switching settings alone. Emits `slot.t2` carrying the same
/// `slot_start_ms` as the `slot.t1` line, so a card's full history is
/// recoverable from the log.
async fn slot_summarize(state: &Arc<AppState>, at_ms: i64) -> Response {
    match run_slot_t2_recording(state, at_ms).await.0 {
        Ok(value) => Response::success(value),
        Err(error) => Response::failure(error),
    }
}

/// Runs one T2 pass, timing it and filing the duration with the compute
/// governor, and hands the caller both the outcome and how long it took.
///
/// Every caller goes through here — the sweeper, `slot backfill`, and the
/// manual RPC — because they all cost the user the same thing, and the
/// dashboard's "about N left" estimate is only as good as the number of real
/// passes behind it. Timing wraps the whole call so a pass that fails halfway
/// still reports the time it burned.
async fn run_slot_t2_recording(
    state: &Arc<AppState>,
    at_ms: i64,
) -> (Result<serde_json::Value, String>, Duration) {
    let began = std::time::Instant::now();
    let outcome = run_slot_t2(state, at_ms).await;
    let took = began.elapsed();
    // A pass that failed before it resolved a card has no slot of its own;
    // `at_ms` is the closest true thing to say about it. Failures are excluded
    // from the median anyway.
    let slot_start_ms = outcome
        .as_ref()
        .ok()
        .and_then(|value| {
            value
                .get("slot_start_ms")
                .and_then(serde_json::Value::as_i64)
        })
        .unwrap_or(at_ms);
    state
        .compute
        .record_summary(slot_start_ms, now_ms(), took, outcome.is_ok());
    (outcome, took)
}

/// One T2 pass over the slot containing `at_ms`: render the prompt, run it
/// through the configured model, persist the card. Shared by the RPC and the
/// background sweeper so both agree on what "summarised" means.
async fn run_slot_t2(state: &Arc<AppState>, at_ms: i64) -> Result<serde_json::Value, String> {
    let started = std::time::Instant::now();
    // Before the budget, not after: the provider only reports its window once
    // the model is resident, so a budget resolved first would be the default's
    // guess exactly when it mattered.
    ensure_remote_llm_model(state).await;
    let budget = afterray_harness::ContextBudget {
        max_rounds: T2_MAX_ROUNDS,
        ..resolve_context_budget(state).await
    };
    let budget_chars = t2_prompt_budget_chars(budget);
    let inputs = run_store(state, move |s| slot_t2_inputs(s, at_ms, budget_chars))
        .await
        .map_err(|error| error.to_string())?;
    let slot_start_ms = inputs.card.slot_start_ms;

    // Reserve the LLM lane for this loop's rounds. Interactive chat still
    // preempts; other background summaries wait until the guard drops.
    let lease_hold = state.models.hold_llm_lease();
    let tools = SlotT2Tools {
        store: afterray_store::ReadOnlyVault::new(&state.store),
        card: &inputs.card,
    };
    let model = afterray_agent::QueueModel {
        models: &state.models,
        priority: afterray_models::JobPriority::Background {
            lease: Some(lease_hold.id()),
        },
        token_sink: None,
        temperature: Some(T2_TEMPERATURE),
    };
    let turn = afterray_harness::run_turn(
        &model,
        &tools,
        &mut afterray_harness::Discard,
        &afterray_harness::LoopConfig {
            budget,
            // The background sweeper has no user waiting on it to stop.
            cancel: afterray_harness::CancelToken::new(),
            // Append-only. A prefix-caching runtime re-prefills only each
            // round's delta, and rewriting an earlier round would invalidate
            // the whole cached prefix. The prompt is built from one slot's
            // card, so it is bounded by construction.
            compaction: None,
        },
        &inputs.system,
        // The T2 prompt is one slot's card: no history, and the card itself is
        // the task.
        afterray_harness::Opening {
            seed: String::new(),
            history: afterray_harness::History::new(),
            task: inputs.user.clone(),
        },
    )
    .await
    .map_err(|error| error.to_string())?;
    drop(lease_hold);
    let latency_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);

    let mut parsed = afterray_store::parse_t2_card_v3(&turn.answer);
    // Grounding: every frame a card points at must be one this slot holds.
    // What replaced the v2 entity check is not weaker, it is the same check on
    // what the v3 card actually asserts — a citation is a promise that a frame
    // can be shown, and only the code knows which frames exist.
    let verification = parsed.as_mut().map(|card| {
        let valid_ids: std::collections::HashSet<String> =
            inputs.card.evidence.moment_ids.iter().cloned().collect();
        afterray_store::ground_t2_details(card, &valid_ids)
    });

    let tool_names: Vec<&str> = turn
        .tool_calls
        .iter()
        .map(|call| call.name.as_str())
        .collect();
    eprintln!(
        "slot.t2 slot={slot_start_ms} prompt_tokens={}/{} rounds={} tools={tool_names:?} \
         out_chars={} latency_ms={latency_ms} parsed={} low_trust={} citations_dropped={}",
        turn.usage.prompt_tokens,
        turn.usage.window_tokens,
        turn.tool_calls.len() + 1,
        turn.answer.chars().count(),
        parsed.is_some(),
        parsed.as_ref().is_some_and(|card| card.low_trust),
        verification
            .as_ref()
            .map_or(0, |report| report.citations_dropped),
    );

    let Some(t2) = parsed else {
        return Err(format!(
            "the model returned no parseable T2 card ({} chars)",
            turn.answer.chars().count()
        ));
    };
    let latency_i64 = i64::try_from(latency_ms).ok();
    let card = inputs.card.clone();
    let t2_for_store = t2.clone();
    if let Err(error) = run_store(state, move |s| {
        s.store
            .put_t2_summary_v3(&card, &t2_for_store, "t2-agent", now_ms(), latency_i64)
    })
    .await
    {
        eprintln!("slot.t2 persist failed slot={slot_start_ms}: {error}");
    }

    Ok(serde_json::json!({
        "slot_start_ms": slot_start_ms,
        "latency_ms": latency_ms,
        "prompt_chars": inputs.user.chars().count(),
        "card": serde_json::to_value(&t2).ok(),
        "tool_calls": serde_json::to_value(&turn.tool_calls).ok(),
        "tool_results": turn.tool_results,
        "verification": serde_json::to_value(&verification).ok(),
        "raw": turn.answer,
    }))
}

/// Rounds are model calls, so this bounds both cost and transcript growth. The
/// transcript is append-only — never pruned — so a prefix-caching runtime
/// re-prefills only each round's delta.
const T2_MAX_ROUNDS: usize = 8;
/// Summary cards are a structured extraction task, so keep sampling stable.
const T2_TEMPERATURE: f32 = 0.1;

/// How long after a slot closes before it is eligible. Frames captured near the
/// boundary land in the vault a beat late; summarising immediately would read a
/// slot that is still filling in.
const T2_SETTLE_MS: i64 = 3 * 60 * 1000;
/// How far back a sweep looks. Bounded so a first run on an old vault does not
/// try to summarise months of history in one go — `slot backfill` is the
/// deliberate way to do that.
const T2_LOOKBACK_DAYS: i64 = 2;
/// Attempts per slot per daemon run. A slot that fails this often is failing
/// for a reason a retry loop will not fix; a restart is a good time to find out
/// whether it has changed, so the count is deliberately not persisted.
const T2_MAX_ATTEMPTS: u32 = 3;
/// Slots summarised per tick. The queue is shared with OCR, so a backlog drains
/// gradually instead of monopolising the model for minutes at a time.
const T2_PER_TICK: usize = 2;

/// The longest a summary will wait for a transcript that has not arrived.
///
/// Measured, not guessed: on a loaded machine the ASR queue reached ten jobs —
/// about fifty minutes of audio — behind a summariser sweeping every five
/// minutes. So a backlog *can* outlive any cap worth having, which is the
/// whole reason there is one. Past half an hour the honest thing is a card
/// that arrives saying the transcript was unavailable, rather than a card that
/// never arrives at all; the user cannot read a summary that is still waiting.
const ASR_WAIT_CAP_MS: i64 = 30 * 60 * 1000;

/// The wall-clock backstop on "ASR is alive", and *only* a backstop.
///
/// Liveness is decided by comparing the last success against the last failure,
/// never against the clock alone: a machine that slept eight hours wakes with
/// an eight-hour-old success and a perfectly healthy worker, and a laptop shut
/// on Friday has a three-day-old one on Monday morning. Judging those stale
/// would drop the wait exactly when the user's first meeting of the week needs
/// it.
///
/// So this catches only the case no other branch can see: a worker that
/// stopped succeeding without ever recording a failure (nothing claims, so
/// nothing fails) — a model file deleted, a runtime that no longer starts.
/// A week is deliberately generous, because the asymmetry is: too generous
/// costs at most one [`ASR_WAIT_CAP_MS`] delay, too strict costs a card that
/// is permanently missing its transcript.
const ASR_ALIVE_STALENESS_MS: i64 = 7 * 24 * 60 * 60 * 1000;

/// Why a slot was summarised without waiting for its transcript.
///
/// Each variant is a different way ASR can fail to arrive, and each is named
/// because the alternative — folding them into one "not waiting" — is what
/// makes an unconditional wait look reasonable right up until the machine
/// where the model was never downloaded produces cards that never come.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AsrProceed {
    /// Nothing in this window is owed a transcript (including: no audio).
    NoTranscriptPending,
    /// Waited long enough. The card goes out honestly incomplete.
    CapElapsed,
    /// Transcription never once succeeded on this vault: cold start, model
    /// absent, worker that cannot run.
    NeverSucceeded,
    /// The most recent thing ASR did was fail.
    FailingNotSucceeding,
    /// It last succeeded so long ago that "alive" is no longer a claim the
    /// vault supports.
    SuccessTooStale,
    /// Every segment still owed a transcript has run its backoff out to
    /// saturation; retries continue, but not on a timescale a card can wait for.
    AllPendingExhausted,
}

impl AsrProceed {
    const fn reason(self) -> &'static str {
        match self {
            Self::NoTranscriptPending => "no transcript pending",
            Self::CapElapsed => "waited out the ASR cap",
            Self::NeverSucceeded => "ASR has never succeeded",
            Self::FailingNotSucceeding => "ASR is failing, not succeeding",
            Self::SuccessTooStale => "ASR's last success is too old to trust",
            Self::AllPendingExhausted => "every pending transcript has exhausted its backoff",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AsrWait {
    /// Summarise now.
    Proceed(AsrProceed),
    /// Skip this slot this round and look again next sweep. Not a state
    /// change: the slot stays `Degraded`, which is the only state
    /// [`due_slot_starts`] ever picks back up.
    Wait,
}

/// Whether a summary should hold off until this window's audio is transcribed.
///
/// The rule the product asked for is "rather two minutes late than a summary
/// that missed the meeting" — but only while waiting is justified. Waiting
/// requires all of: something is actually pending, ASR is demonstrably alive
/// (its last success is more recent than its last failure, one exists at all,
/// and it is not absurdly old), and the cap has not elapsed. Everything else
/// proceeds, with a named reason.
///
/// Pure: the vault reads happen in the caller so this can be tested against
/// every shape of a broken ASR without one.
const fn asr_wait_verdict(
    health: &AsrHealth,
    has_untranscribed: bool,
    slot_end_ms: i64,
    now_ms: i64,
) -> AsrWait {
    if !has_untranscribed {
        return AsrWait::Proceed(AsrProceed::NoTranscriptPending);
    }
    if slot_end_ms.saturating_add(ASR_WAIT_CAP_MS) <= now_ms {
        return AsrWait::Proceed(AsrProceed::CapElapsed);
    }
    // Global counts against a per-slot fact, so `waiting_segments == 0` here
    // means the two reads raced; that is not evidence of exhaustion.
    if health.waiting_segments > 0 && health.exhausted_segments >= health.waiting_segments {
        return AsrWait::Proceed(AsrProceed::AllPendingExhausted);
    }
    let Some(last_success_ms) = health.last_success_ms else {
        return AsrWait::Proceed(AsrProceed::NeverSucceeded);
    };
    if let Some(last_failure_ms) = health.last_failure_ms
        && last_failure_ms > last_success_ms
    {
        return AsrWait::Proceed(AsrProceed::FailingNotSucceeding);
    }
    if now_ms.saturating_sub(last_success_ms) > ASR_ALIVE_STALENESS_MS {
        return AsrWait::Proceed(AsrProceed::SuccessTooStale);
    }
    AsrWait::Wait
}

/// Every occupied slot that T1 marked ready, has closed and settled, and has no
/// T2 card yet — oldest first, so a backlog fills in the order it happened.
///
/// No ASR gate: this is the list of slots that *want* summarising, which is
/// what the backlog count reports and what `slot backfill` works through. The
/// sweeper takes [`slots_ready_for_t2`] instead.
fn slots_awaiting_t2(store: &Vault, interval_ms: i64, now: i64, lookback_days: i64) -> Vec<i64> {
    slot_windows_awaiting_t2(store, interval_ms, now, lookback_days)
        .into_iter()
        .map(|(slot_start_ms, _)| slot_start_ms)
        .collect()
}

/// The same walk, keeping each slot's end — the ASR gate needs it to know how
/// long this particular card has already been waiting.
fn slot_windows_awaiting_t2(
    store: &Vault,
    interval_ms: i64,
    now: i64,
    lookback_days: i64,
) -> Vec<(i64, i64)> {
    let mut due = Vec::new();
    let mut day_ms = now;
    for _ in 0..=lookback_days.max(0) {
        let Ok(summary) = store.day_summary(day_ms, interval_ms) else {
            continue;
        };
        due.extend(due_slot_windows(&summary.slots, now));
        day_ms = summary.day_start_ms.saturating_sub(1);
    }
    due.sort_unstable();
    due.dedup_by_key(|(slot_start_ms, _)| *slot_start_ms);
    due
}

/// The automatic sweeper's list: due slots, minus the ones whose transcript is
/// still worth waiting for.
///
/// Blocking, and it must stay that way — every call here is a synchronous
/// `Vault` read, so async callers reach it through `run_store`.
///
/// The health snapshot is taken once for the whole sweep (ASR is one worker
/// with one model; its health is not a property of a slot), and doubles as the
/// short circuit: with nothing anywhere owed a transcript, no slot needs the
/// per-slot query at all.
fn slots_ready_for_t2(store: &Vault, interval_ms: i64, now: i64, lookback_days: i64) -> T2Sweep {
    let windows = slot_windows_awaiting_t2(store, interval_ms, now, lookback_days);
    if windows.is_empty() {
        return T2Sweep::default();
    }
    // Fail open. A summary held back by a query that will not run is a card
    // the user never sees, which is worse than the incomplete card this whole
    // gate exists to prevent.
    let health = match store.asr_health(now) {
        Ok(health) => health,
        Err(error) => {
            eprintln!("slot.t2 sweeper: could not read ASR health, not waiting: {error}");
            return T2Sweep {
                ready: windows
                    .into_iter()
                    .map(|(slot_start_ms, _)| slot_start_ms)
                    .collect(),
                waiting_on_asr: 0,
            };
        }
    };
    let mut waiting_on_asr = 0_usize;
    let ready = windows
        .into_iter()
        .filter(|&(slot_start_ms, slot_end_ms)| {
            let has_untranscribed = health.waiting_segments > 0
                && store
                    .has_untranscribed_audio_between(slot_start_ms, slot_end_ms)
                    .unwrap_or(false);
            match asr_wait_verdict(&health, has_untranscribed, slot_end_ms, now) {
                AsrWait::Wait => {
                    eprintln!(
                        "slot.t2 sweeper: slot={slot_start_ms} waiting for a transcript \
                         ({} segment(s) queued, up to {} more)",
                        health.waiting_segments,
                        human_duration(Duration::from_millis(
                            u64::try_from(
                                slot_end_ms
                                    .saturating_add(ASR_WAIT_CAP_MS)
                                    .saturating_sub(now)
                            )
                            .unwrap_or_default()
                        ))
                    );
                    waiting_on_asr += 1;
                    false
                }
                // The line that would have explained the card written before
                // its transcript existed: why this one is not waiting.
                AsrWait::Proceed(AsrProceed::NoTranscriptPending) => true,
                AsrWait::Proceed(reason) => {
                    eprintln!(
                        "slot.t2 sweeper: slot={slot_start_ms} summarising without its \
                         transcript — {}",
                        reason.reason()
                    );
                    true
                }
            }
        })
        .map(|(slot_start_ms, _)| slot_start_ms)
        .collect();
    T2Sweep {
        ready,
        waiting_on_asr,
    }
}

/// What one sweep found: the slots to summarise now, and how many were held
/// back for a transcript.
///
/// The second number exists so the sweeper does not report a backlog it is
/// deliberately holding as "drained" and cancel the user's "run now" override
/// on the strength of it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct T2Sweep {
    ready: Vec<i64>,
    waiting_on_asr: usize,
}

// @dec:raw-input-events-expire — docs/decisions/active/product/2026-08-20-raw-input-events-expire.md
/// The selection rule on its own, so the four things that make it wrong — the
/// state filter, the settle window, the expiry cutoff, and the ASR gate that
/// reads the end it returns — can be tested without a vault.
///
/// The cutoff is the one that gives up rather than waits. Once a slot's input
/// events are past `RAW_EVENT_RETENTION_MS` they are gone, and a summary
/// written from what is left would describe the screen while saying nothing
/// about the person in front of it — with no way for the reader to tell that
/// from a slot where the user genuinely sat still. A card that was never
/// written is honest about being absent; one written from half the evidence is
/// not, and it is written once and never revised.
///
/// This applies to the explicit backfill too, which shares this rule. Asking
/// for the summary does not put the evidence back.
fn due_slot_windows(slots: &[afterray_store::DaySlot], now: i64) -> Vec<(i64, i64)> {
    let evidence_expires_before = now.saturating_sub(afterray_store::RAW_EVENT_RETENTION_MS);
    slots
        .iter()
        // Degraded is precisely "T1 said summarise me, nothing has".
        .filter(|slot| slot.state == SlotSummaryState::Degraded)
        .filter(|slot| slot.slot_end_ms + T2_SETTLE_MS <= now)
        .filter(|slot| slot.slot_end_ms >= evidence_expires_before)
        .map(|slot| (slot.slot_start_ms, slot.slot_end_ms))
        .collect()
}

/// Ceiling on one backfill call. The RPC blocks until it returns, and each slot
/// is a full model round trip — better to finish and report than to hold the
/// socket open for an hour. Re-run to continue.
const T2_BACKFILL_CAP: usize = 40;

async fn slot_backfill(state: &Arc<AppState>, days: i64) -> Response {
    let due = slots_awaiting_t2(&state.store, capture_interval_ms(state), now_ms(), days);
    let total = due.len();
    let mut summarised = 0_usize;
    let mut failures: Vec<serde_json::Value> = Vec::new();
    for slot_start_ms in due.into_iter().take(T2_BACKFILL_CAP) {
        match run_slot_t2_recording(state, slot_start_ms).await.0 {
            Ok(_) => summarised += 1,
            Err(error) => failures.push(serde_json::json!({
                "slot_start_ms": slot_start_ms,
                "error": error,
            })),
        }
    }
    Response::success(serde_json::json!({
        "eligible": total,
        "attempted": summarised + failures.len(),
        "summarised": summarised,
        "remaining": total.saturating_sub(T2_BACKFILL_CAP),
        "failures": failures,
    }))
}

/// Closes the loop the day panel was missing: T1 has been marking slots ready
/// since capture began, but nothing ever ran T2 on them, so every row fell back
/// to a bare app list. This is the only automatic caller.
/// Keeps the text DF corpus current: the background frequencies that let T1
/// tell a slot's own content from the user's everyday chrome. Small batches
/// on a timer — a cold vault backfills two weeks over a few minutes without
/// ever holding the store lock long.
fn spawn_text_df_maintainer(state: Arc<AppState>) {
    let mut shutdown = state.shutdown.subscribe();
    let lifecycle_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        // After the model runtimes settle; this touches only SQLite.
        tokio::time::sleep(Duration::from_secs(20)).await;
        let interval_ms = i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000);
        let mut total = 0_usize;
        loop {
            let processed = {
                let state = Arc::clone(&state);
                tokio::task::spawn_blocking(move || {
                    state.store.advance_text_df(now_ms(), interval_ms, 12)
                })
                .await
                .unwrap_or_else(|join| {
                    eprintln!("text.df task panicked: {join}");
                    Ok(0)
                })
                .unwrap_or_else(|error| {
                    eprintln!("text.df advance failed: {error}");
                    0
                })
            };
            total += processed;
            if processed > 0 && total % 96 < 12 {
                eprintln!("text.df corpus advanced ({total} slots this run)");
            }
            // Drained: check twice a minute for newly closed slots. Behind:
            // keep pulling with short pauses so a backfill finishes promptly.
            let pause = if processed == 0 { 30 } else { 2 };
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                }
                () = tokio::time::sleep(Duration::from_secs(pause)) => {}
            }
        }
    });
    lifecycle_state.lifecycle.track_task(task);
}

fn spawn_asr_sweeper(state: Arc<AppState>) {
    let mut shutdown = state.shutdown.subscribe();
    state.asr_changed.notify_one();
    let lifecycle_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        // Logged on change only, like the T2 sweeper's.
        let mut blocked_reason: Option<String> = None;
        loop {
            let conditions = compute::MachineConditions::probe();
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                    continue;
                }
                () = state.asr_changed.notified() => {}
                // On battery this stretches to five minutes instead of
                // stopping: the audio rows are a durable backlog, so the work
                // still drains, just slower.
                () = tokio::time::sleep(state.compute.asr_sweep_interval(conditions, now_ms())) => {}
            }
            if let Err(refusal) = state.compute.decide(
                afterray_protocol::ComputeWorkload::Asr,
                conditions,
                now_ms(),
            ) {
                if blocked_reason.as_deref() != Some(refusal.reason.as_str()) {
                    eprintln!("asr backlog: holding off — {}", refusal.reason);
                    blocked_reason = Some(refusal.reason);
                }
                continue;
            }
            if blocked_reason.take().is_some() {
                eprintln!("asr backlog: resuming");
            }
            match run_one_audio_transcription(&state).await {
                Ok(true) => state.asr_changed.notify_one(),
                Ok(false) => {
                    if state
                        .compute
                        .clear_force(afterray_protocol::ComputeWorkload::Asr)
                    {
                        eprintln!("asr backlog: drained, override ended");
                    }
                }
                Err(error) => eprintln!("asr backlog: {error}"),
            }
        }
        eprintln!("asr backlog: stopped");
    });
    lifecycle_state.lifecycle.track_task(task);
}

/// Feeds the governor's GPU window at 1 Hz. A failed probe records nothing —
/// the window ages out on its own, which the summary gate reads as
/// "unavailable" (fail-closed), never as "idle".
fn spawn_gpu_sampler(state: Arc<AppState>) {
    let mut shutdown = state.shutdown.subscribe();
    let lifecycle_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                }
                _ = interval.tick() => {
                    if let Some(value) = afterray_platform_macos::gpu_utilization() {
                        state.compute.record_gpu_utilization(now_ms(), value);
                    }
                }
            }
        }
        eprintln!("gpu sampler: stopped");
    });
    lifecycle_state.lifecycle.track_task(task);
}

async fn run_one_audio_transcription(state: &Arc<AppState>) -> Result<bool, String> {
    let claimed = run_store(state, |state| {
        state.store.claim_audio_transcription(now_ms())
    })
    .await
    .map_err(|error| error.to_string())?;
    let Some(claimed) = claimed else {
        return run_one_audio_alignment(state).await;
    };
    let segment = claimed.segment;
    let path = match materialize_audio_for_asr(state, &segment).await {
        Ok(path) => path,
        Err(error) => {
            fail_claimed_audio(state, &segment.id, claimed.attempts, &error).await;
            return Err(error);
        }
    };
    let outcome = async {
        let job = state
            .models
            .submit(ModelInput::Asr {
                audio_path: path.clone(),
                language: None,
            })
            .await
            .map_err(|error| error.to_string())?;
        let snapshot = state
            .models
            .wait(&job)
            .await
            .map_err(|error| error.to_string())?;
        match snapshot.output {
            Some(ModelOutput::Asr { text, language }) => {
                if text.trim().is_empty() {
                    eprintln!(
                        "asr produced no visible text for {} ({})",
                        segment.id,
                        language.as_deref().unwrap_or("auto")
                    );
                }
                let stored_segment = segment.clone();
                let stored_text = text.clone();
                let stored_language = language.clone();
                let adapter = snapshot.adapter.clone();
                let evidence_id = run_store(state, move |state| {
                    state.store.complete_audio_transcription(
                        &stored_segment,
                        &stored_text,
                        stored_language.as_deref(),
                        &adapter,
                        now_ms(),
                    )
                })
                .await
                .map_err(|error| error.to_string())?;
                // Embeddings are switched off; see `search_hits`.
                let _ = evidence_id;
                Ok(())
            }
            Some(_) => Err(format!(
                "ASR job {} returned a non-transcript output",
                snapshot.id
            )),
            None => Err(snapshot
                .last_error
                .unwrap_or_else(|| format!("ASR job {} ended {:?}", snapshot.id, snapshot.state))),
        }
    }
    .await;
    let _ = tokio::fs::remove_file(&path).await;
    if let Err(error) = outcome {
        fail_claimed_audio(state, &segment.id, claimed.attempts, &error).await;
        return Err(format!("{} failed: {error}", segment.id));
    }
    Ok(true)
}

// @dec:forced-aligned-audio-transcript-cues — docs/decisions/active/product/2026-08-24-forced-aligned-audio-transcript-cues.md
async fn run_one_audio_alignment(state: &Arc<AppState>) -> Result<bool, String> {
    // Pending transcripts are durable and can wait. Do not claim work or
    // decrypt an audio artifact until the optional aligner is actually on
    // disk; the download completion path wakes this sweeper explicitly.
    if !subtitle_aligner_is_present() {
        return Ok(false);
    }
    let claimed = run_store(state, |state| state.store.claim_audio_alignment(now_ms()))
        .await
        .map_err(|error| error.to_string())?;
    let Some(claimed) = claimed else {
        return Ok(false);
    };
    let segment = claimed.segment;
    let path = match materialize_audio_for_asr(state, &segment).await {
        Ok(path) => path,
        Err(error) => {
            fail_claimed_alignment(state, &segment.id, claimed.attempts, &error).await;
            eprintln!("subtitle alignment {} failed: {error}", segment.id);
            return Ok(true);
        }
    };
    let language = alignment_language_or_infer(claimed.language.as_deref(), &claimed.transcript);
    let outcome = async {
        let job = state
            .models
            .submit(ModelInput::Align {
                audio_path: path.clone(),
                text: claimed.transcript,
                language,
            })
            .await
            .map_err(|error| error.to_string())?;
        let snapshot = state
            .models
            .wait(&job)
            .await
            .map_err(|error| error.to_string())?;
        match snapshot.output {
            Some(ModelOutput::Alignment { cues }) => {
                let stored_segment = segment.clone();
                let adapter = snapshot.adapter.clone();
                let duration_ms = stored_segment
                    .ended_at_ms
                    .saturating_sub(stored_segment.started_at_ms);
                let cues = bound_alignment_cues_to_segment(cues, duration_ms)?;
                run_store(state, move |state| {
                    state
                        .store
                        .complete_audio_alignment(&stored_segment, &cues, &adapter, now_ms())
                })
                .await
                .map_err(|error| error.to_string())
            }
            Some(_) => Err(format!(
                "subtitle alignment job {} returned a non-alignment output",
                snapshot.id
            )),
            None => Err(snapshot.last_error.unwrap_or_else(|| {
                format!(
                    "subtitle alignment job {} ended {:?}",
                    snapshot.id, snapshot.state
                )
            })),
        }
    }
    .await;
    let _ = tokio::fs::remove_file(&path).await;
    if let Err(error) = outcome {
        fail_claimed_alignment(state, &segment.id, claimed.attempts, &error).await;
        eprintln!("subtitle alignment {} failed: {error}", segment.id);
    }
    // Text was durable before this independent refinement began. Whether the
    // aligner succeeded or entered backoff, this item was consumed and the
    // sweeper should continue with the rest of the queue.
    Ok(true)
}

fn subtitle_aligner_is_present() -> bool {
    spec_by_id(QWEN3_ALIGNER_PACK_ID).is_some_and(|pack| pack.inspect().present)
}

/// Container/codec padding can make decoded PCM a few milliseconds longer
/// than the exact capture interval in the vault. Clipping a final cue is safe;
/// moving overlapping or wholly out-of-range text would manufacture timing
/// evidence the aligner did not produce.
fn bound_alignment_cues_to_segment(
    cues: Vec<TranscriptCue>,
    duration_ms: i64,
) -> Result<Vec<TranscriptCue>, String> {
    if duration_ms <= 0 {
        return Err("audio segment has no positive duration".into());
    }
    if cues.is_empty() {
        return Err("subtitle alignment returned no cues for a non-empty transcript".into());
    }
    let mut bounded: Vec<TranscriptCue> = Vec::with_capacity(cues.len());
    for mut cue in cues {
        let previous_end_ms = bounded.last().map_or(0, |previous| previous.end_offset_ms);
        if cue.start_offset_ms < 0
            || cue.start_offset_ms < previous_end_ms
            || cue.start_offset_ms >= duration_ms
        {
            return Err(format!(
                "alignment cue {} starts outside its trustworthy interval",
                cue.ordinal
            ));
        }
        cue.ordinal = u32::try_from(bounded.len()).unwrap_or(u32::MAX);
        cue.end_offset_ms = cue.end_offset_ms.min(duration_ms);
        if cue.end_offset_ms <= cue.start_offset_ms {
            return Err(format!(
                "alignment cue {} has no positive trustworthy interval",
                cue.ordinal
            ));
        }
        bounded.push(cue);
    }
    Ok(bounded)
}

fn alignment_language_or_infer(language: Option<&str>, transcript: &str) -> String {
    if let Some(language) = language.filter(|language| !language.trim().is_empty()) {
        return language.to_owned();
    }
    if transcript
        .chars()
        .any(|character| matches!(u32::from(character), 0x3040..=0x30ff))
    {
        "Japanese".to_owned()
    } else if transcript
        .chars()
        .any(|character| matches!(u32::from(character), 0xac00..=0xd7af))
    {
        "Korean".to_owned()
    } else if transcript
        .chars()
        .any(|character| matches!(u32::from(character), 0x3400..=0x9fff))
    {
        "Chinese".to_owned()
    } else {
        "English".to_owned()
    }
}

async fn materialize_audio_for_asr(
    state: &Arc<AppState>,
    segment: &afterray_protocol::AudioSegment,
) -> Result<PathBuf, String> {
    let artifact_id = segment.audio_artifact_id.clone();
    let segment_id = segment.id.clone();
    run_store(state, move |state| {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;

        let payload = state
            .store
            .read_artifact(&artifact_id)
            .map_err(|error| error.to_string())?;
        let directory = state.data_dir.join("capture-staging");
        std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        let path = directory.join(format!(
            "asr-retry-{segment_id}-{}.m4a",
            uuid::Uuid::now_v7()
        ));
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("could not materialize encrypted audio: {error}"))?;
        if let Err(error) = file
            .write_all(&payload.bytes)
            .and_then(|()| file.sync_all())
        {
            let _ = std::fs::remove_file(&path);
            return Err(format!("could not materialize encrypted audio: {error}"));
        }
        Ok(path)
    })
    .await
}

async fn fail_claimed_audio(state: &Arc<AppState>, segment_id: &str, attempts: u32, error: &str) {
    // The saturation point is shared with the store: past it the delay stops
    // growing, which is what `AsrHealth::exhausted_segments` counts.
    let delay_minutes = 1_i64 << attempts.min(afterray_store::AUDIO_BACKOFF_SATURATION_ATTEMPTS);
    let now = now_ms();
    let next = now.saturating_add(delay_minutes * 60 * 1_000);
    let segment_id = segment_id.to_owned();
    let error = error.to_owned();
    if let Err(store_error) = run_store(state, move |state| {
        state
            .store
            .fail_audio_transcription(&segment_id, &error, next, now)
    })
    .await
    {
        eprintln!("asr backlog: could not persist failure: {store_error}");
    }
}

async fn fail_claimed_alignment(
    state: &Arc<AppState>,
    segment_id: &str,
    attempts: u32,
    error: &str,
) {
    let delay_minutes = 1_i64 << attempts.min(afterray_store::AUDIO_BACKOFF_SATURATION_ATTEMPTS);
    let now = now_ms();
    let next = now.saturating_add(delay_minutes * 60 * 1_000);
    let segment_id = segment_id.to_owned();
    let error = error.to_owned();
    if let Err(store_error) = run_store(state, move |state| {
        state
            .store
            .fail_audio_alignment(&segment_id, &error, next, now)
    })
    .await
    {
        eprintln!("subtitle alignment: could not persist failure: {store_error}");
    }
}

/// How far back the freeze looks for slots whose acts are not yet frozen.
///
/// Derived from the event lifetime, never a constant of its own: the freeze has
/// to reach every slot whose events are still alive, and one hour of slack
/// covers a slot straddling the cutoff. A fixed window shorter than the
/// lifetime leaves slots that can never be frozen and whose acts are therefore
/// lost when the events go — which is what a hardcoded 36 hours did once the
/// events stopped expiring on their own 48-hour clock.
const ACTS_FREEZE_LOOKBACK_MS: i64 = afterray_store::RAW_EVENT_RETENTION_MS + 60 * 60 * 1000;

/// Ceiling per tick. One freeze rebuilds a card (per-frame AX decryption), so
/// the backlog drains over several ticks rather than stalling one.
const ACTS_FREEZE_PER_TICK: usize = 4;

/// Freezes the acts of every sealed slot that still has events and no frozen
/// copy.
///
/// "Sealed" is the same settle window T2 uses: a slot still gaining OCR is
/// still gaining runs, and acts are attributed to runs.
async fn freeze_slot_acts(state: &Arc<AppState>, now: i64) {
    let from = now.saturating_sub(ACTS_FREEZE_LOOKBACK_MS);
    let due = match run_store(state, move |s| s.store.slots_missing_acts(from, now)).await {
        Ok(due) => due,
        Err(error) => {
            eprintln!("slot.acts freeze: listing slots failed: {error}");
            return;
        }
    };
    freeze_slots(state, due, now, ACTS_FREEZE_PER_TICK).await;
}

/// Freezes the acts of `slots`, up to `budget` of them.
///
/// Shared by the periodic freeze and the expiry sweep, so both obey the same
/// settle rule and the same per-tick ceiling. Returns how many slots were newly
/// frozen — the expiry sweep needs that to know whether it may delete yet.
async fn freeze_slots(state: &Arc<AppState>, slots: Vec<i64>, now: i64, budget: usize) -> usize {
    let interval_ms = i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000);
    let mut frozen = 0_usize;
    for slot_start_ms in slots {
        if frozen >= budget {
            break;
        }
        let bounds = match run_store(state, move |s| {
            Ok::<_, StoreError>(s.store.summary_slot_bounds(slot_start_ms))
        })
        .await
        {
            Ok(bounds) => bounds,
            Err(error) => {
                eprintln!("slot.acts freeze: slot={slot_start_ms} bounds failed: {error}");
                continue;
            }
        };
        if bounds.end_ms + T2_SETTLE_MS > now {
            continue;
        }
        match run_store(state, move |s| {
            s.store.materialize_slot_acts(slot_start_ms, interval_ms)
        })
        .await
        {
            Ok(true) => {
                frozen += 1;
                eprintln!("slot.acts freeze: froze slot={slot_start_ms}");
            }
            Ok(false) => {}
            Err(error) => {
                eprintln!("slot.acts freeze: slot={slot_start_ms} failed: {error}");
            }
        }
    }
    frozen
}

// @dec:raw-input-events-expire — docs/decisions/active/product/2026-08-20-raw-input-events-expire.md
/// Deletes raw input events past `RAW_EVENT_RETENTION_MS` — but only once the
/// acts of every slot they cover are frozen.
///
/// The order is the entire safety argument. A card built from no events makes
/// no claim about the user at all, which is the right failure: it does not read
/// an absence of events as "the user did nothing". But it also cannot say how
/// much was typed or clicked, and that much is worth keeping. So the freeze
/// runs first, and a window that is not fully frozen is left for a later tick
/// rather than deleted early. The delay is bounded by the freeze ceiling and
/// only ever appears after the daemon has been down long enough to build a
/// backlog; the alternative — deleting on schedule and losing acts nobody can
/// reconstruct — is not recoverable.
///
/// What the freeze keeps is counts and labels. `acts::ActContent` — the typed
/// text and the field values — is deliberately never frozen, so this sweep is
/// what makes it go.
async fn expire_raw_input_events(state: &Arc<AppState>, now: i64) {
    let cutoff = now.saturating_sub(afterray_store::RAW_EVENT_RETENTION_MS);
    let oldest = match run_store(state, |s| s.store.oldest_input_event_ms()).await {
        Ok(Some(oldest)) => oldest,
        Ok(None) => return,
        Err(error) => {
            eprintln!("input events expiry: reading the oldest event failed: {error}");
            return;
        }
    };
    if oldest >= cutoff {
        return;
    }

    let pending = match run_store(state, move |s| s.store.slots_missing_acts(oldest, cutoff)).await
    {
        Ok(pending) => pending,
        Err(error) => {
            eprintln!("input events expiry: listing unfrozen slots failed: {error}");
            return;
        }
    };
    if !pending.is_empty() {
        let frozen = freeze_slots(state, pending, now, ACTS_FREEZE_PER_TICK).await;
        eprintln!(
            "input events expiry: froze {frozen} slot(s) before deleting; deferring the delete"
        );
        return;
    }

    match run_store(state, move |s| s.store.prune_input_events_before(cutoff)).await {
        Ok(0) => {}
        Ok(removed) => {
            eprintln!("input events expiry: deleted {removed} row(s) older than {cutoff}")
        }
        Err(error) => eprintln!("input events expiry: delete failed: {error}"),
    }
}

fn spawn_slot_summarizer(state: Arc<AppState>) {
    let period = t2_sweep_period();
    if period.is_zero() {
        eprintln!("slot.t2 sweeper: disabled by AFTERRAY_T2_SWEEP_SECONDS=0");
        return;
    }
    let mut shutdown = state.shutdown.subscribe();
    let lifecycle_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        // Long enough for the model runtime to come up; a sweep that races it
        // just burns an attempt on every slot.
        tokio::time::sleep(Duration::from_secs(45)).await;
        let mut attempts: std::collections::HashMap<i64, u32> = std::collections::HashMap::new();
        // Logged on change only. At one tick every five minutes, a machine in
        // use all day would otherwise write the same line hundreds of times.
        let mut blocked_reason: Option<String> = None;
        let mut timer = tokio::time::interval(period);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                    continue;
                }
                // "Run now" nudges this, so the button acts within a second
                // instead of somewhere in the next five minutes.
                () = state.t2_changed.notified() => {}
                _ = timer.tick() => {}
            }

            // Freezing acts runs before — and independently of — the T2 gate.
            // It is a short read and one small write with no model in it, and
            // the deadline it races is physical: the events expire in 48 hours
            // whether or not the machine was ever on AC power with a charged
            // battery. Gating it behind T2's conditions would lose acts on
            // exactly the laptops that stay unplugged.
            freeze_slot_acts(&state, now_ms()).await;

            // Then delete what the freeze has made safe to lose. This must run
            // after the freeze in the same tick and never before it: the freeze
            // is what turns an expiring event into a kept act.
            expire_raw_input_events(&state, now_ms()).await;

            // The runtime markers, on their own shorter deadline. The R3 trees
            // are content and expire with the rest of it, oldest-first, inside
            // `enforce_retention`. A marker's deadline is wall-clock, so it
            // cannot hang off capture (which stops when the user pauses) or off
            // the T2 gate (which waits for power) — this tick runs while the
            // daemon is up, whether or not anything is being recorded.
            if let Err(error) = run_store(&state, |s| s.store.prune_signal_gaps(now_ms())).await {
                eprintln!("signal marker retention failed: {error}");
            }

            // OCR is on the critical path for the frames still arriving; T2 is
            // not. Yield the queue and pick the backlog up next tick.
            if state.models.ocr_in_flight() {
                continue;
            }

            // Cheap to check, so check before touching the vault at all. The
            // governor folds the machine gate together with the user's own
            // mode and suspension, so one refusal string explains all three.
            if let Err(refusal) = state.compute.decide(
                afterray_protocol::ComputeWorkload::Summary,
                compute::MachineConditions::probe(),
                now_ms(),
            ) {
                if blocked_reason.as_deref() != Some(refusal.reason.as_str()) {
                    eprintln!("slot.t2 sweeper: holding off — {}", refusal.reason);
                    blocked_reason = Some(refusal.reason);
                }
                continue;
            }
            if blocked_reason.take().is_some() {
                eprintln!("slot.t2 sweeper: conditions met, resuming");
            }

            // Through `run_store`: this walks up to three days of slot cards
            // and now also asks the ASR queue where it stands, all of it
            // synchronous vault work that must not run on a tokio worker.
            let interval_ms = capture_interval_ms(&state);
            let now = now_ms();
            let due = run_store(&state, move |s| {
                slots_ready_for_t2(&s.store, interval_ms, now, T2_LOOKBACK_DAYS)
            })
            .await;
            // A slot held back for its transcript is not a drained backlog:
            // ending the override here would put the work the user pointed at
            // back under the usual gates the moment it becomes runnable.
            if due.ready.is_empty()
                && due.waiting_on_asr == 0
                && state
                    .compute
                    .clear_force(afterray_protocol::ComputeWorkload::Summary)
            {
                // Nothing left to force. Ending the override here rather than
                // letting it time out means the machine goes back under its
                // usual gates the moment the pile the user pointed at is gone.
                eprintln!("slot.t2 sweeper: backlog drained, override ended");
            }
            let mut ran = 0;
            for slot_start_ms in due.ready {
                // A forced run is draining a backlog the user is watching, so it
                // works through the lot instead of two slots every five minutes —
                // and it stops the moment the override expires or is withdrawn,
                // rather than running on past the point they stopped watching.
                let forced = state
                    .compute
                    .forced_until_ms(afterray_protocol::ComputeWorkload::Summary, now_ms())
                    .is_some();
                if !forced && ran >= T2_PER_TICK {
                    break;
                }
                let attempt = attempts.entry(slot_start_ms).or_default();
                if *attempt >= T2_MAX_ATTEMPTS {
                    continue;
                }
                *attempt += 1;
                let attempt = *attempt;
                ran += 1;
                let (outcome, took) = run_slot_t2_recording(&state, slot_start_ms).await;
                match outcome {
                    Ok(_) => {
                        attempts.remove(&slot_start_ms);
                        eprintln!(
                            "slot.t2 sweeper: summarised slot={slot_start_ms} in {}",
                            human_duration(took)
                        );
                    }
                    Err(error) => {
                        eprintln!(
                            "slot.t2 sweeper: slot={slot_start_ms} attempt={attempt}/{T2_MAX_ATTEMPTS} failed after {}: {error}",
                            human_duration(took)
                        );
                    }
                }
            }
        }
        eprintln!("slot.t2 sweeper: stopped");
    });
    lifecycle_state.lifecycle.track_task(task);
}

const MLX_IDLE_TIMEOUT: Duration = Duration::from_secs(120);
const MLX_IDLE_REAPER_PERIOD: Duration = Duration::from_secs(5);

// @dec:mlx-idle-lifetime — docs/decisions/active/architecture/2026-08-24-mlx-idle-lifetime.md
fn spawn_mlx_idle_reaper(state: Arc<AppState>) {
    let mut shutdown = state.shutdown.subscribe();
    let lifecycle_state = Arc::clone(&state);
    let task = tokio::spawn(async move {
        let mut timer = tokio::time::interval(MLX_IDLE_REAPER_PERIOD);
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                }
                _ = timer.tick() => {
                    for (pack_id, adapter) in &state.mlx_adapters {
                        if adapter.unload_if_idle(MLX_IDLE_TIMEOUT).await {
                            eprintln!(
                                "mlx worker: unloaded {pack_id} after {}s without a request",
                                MLX_IDLE_TIMEOUT.as_secs()
                            );
                        }
                    }
                }
            }
        }
        eprintln!("mlx worker idle reaper: stopped");
    });
    lifecycle_state.lifecycle.track_task(task);
}

async fn summarize(state: &Arc<AppState>, session_id: &str) -> Response {
    let session_id_owned = session_id.to_owned();
    let text = match run_store(state, move |s| s.store.session_text(&session_id_owned)).await {
        Ok(text) if !text.is_empty() => text,
        Ok(_) => return Response::failure("the session has no OCR or transcript evidence yet"),
        Err(error) => return Response::failure(error.to_string()),
    };
    let prompt =
        format!("Summarize this local computer activity with concrete evidence:\n\n{text}");
    let job_id = match state
        .models
        .submit(ModelInput::Llm {
            messages: Vec::new(),
            prompt,
            system: Some(
                "You are AfterRay. Be concise and never invent missing evidence.".to_owned(),
            ),
            temperature: Some(T2_TEMPERATURE),
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

/// Builds the T1 card and records what it was derived from.
///
/// The log line is the audit trail for the T1 half of a card: which slot, how
/// many moments went in, what the gate decided, and which map entries a T2
/// agent will see. Pair it with the `slot.t2` line emitted by the summariser
/// to reconstruct a card's full history.
fn slot_card_for(
    state: &AppState,
    at_ms: i64,
) -> Result<afterray_store::SlotCard, afterray_store::StoreError> {
    let interval_ms = i64::try_from(state.capture_interval.as_millis()).unwrap_or(10_000);
    let card = state.store.slot_card(at_ms, interval_ms)?;
    let (run_count, gap_count, dedup_chars) =
        card.timeline
            .iter()
            .fold(
                (0_usize, 0_usize, 0_usize),
                |(runs, gaps, chars), entry| match entry {
                    afterray_store::TimelineEntry::Run(run) => {
                        (runs + 1, gaps, chars + run.total_chars)
                    }
                    afterray_store::TimelineEntry::Gap(_) => (runs, gaps + 1, chars),
                },
            );
    eprintln!(
        "slot.t1 slot={} day={} state={:?} moments={} ocr={} ax={} switches={} idle={:.2} \
         runs={run_count} gaps={gap_count} revisits={} dedup_chars={dedup_chars} theme={:?}",
        card.slot_start_ms,
        card.local_day,
        card.state,
        card.facts.moment_count,
        card.facts.ocr_moment_count,
        card.facts.ax_moment_count,
        card.facts.switch_count,
        card.facts.idle_ratio,
        card.revisits.len(),
        card.theme_key.as_deref().unwrap_or("-"),
    );
    Ok(card)
}

/// Everything one T2 pass needs: the card (for the tool host and
/// persistence) and the rendered prompt pair.
struct SlotT2Inputs {
    card: afterray_store::SlotCard,
    system: String,
    user: String,
}

/// Neighbouring cards injected as context. Two, not three: they carry their
/// descriptions now, and the third one only pushed the slot's own evidence out
/// of the window.
const T2_PREV_CARDS: usize = 2;

fn slot_t2_inputs(
    state: &AppState,
    at_ms: i64,
    budget_chars: usize,
) -> Result<SlotT2Inputs, afterray_store::StoreError> {
    let mut card = slot_card_for(state, at_ms)?;
    let stored = state
        .languages
        .lock()
        .map_or_else(|_| default_language(), |langs| langs.1.clone());
    let language = agent::resolve_language(&stored);
    let prev_cards = state
        .store
        .previous_slot_titles(card.slot_start_ms, T2_PREV_CARDS)
        .unwrap_or_default();
    // History-aware rendering: the DF corpus decides which lines carry
    // information and which are the user's everyday chrome. An empty corpus
    // (first run) degrades to pattern-and-position scoring, never an error.
    let background = state.store.background_stats(&card).unwrap_or_else(|error| {
        eprintln!("slot.prompt background stats unavailable: {error}");
        afterray_store::infoscore::BackgroundStats::empty()
    });
    afterray_store::attach_entity_candidates(&mut card, &background);
    let user =
        afterray_store::render_t2_prompt(&card, &prev_cards, &language, &background, budget_chars);
    eprintln!(
        "slot.prompt slot={} language={language} budget_chars={budget_chars} user_chars={}",
        card.slot_start_ms,
        user.chars().count()
    );
    // The catalog is cut to this slot's evidence: a silent slot is never told
    // about a transcript tool, which measured as a whole wasted round.
    let system = afterray_store::render_t2_system_prompt(card.facts.has_audio);
    Ok(SlotT2Inputs { card, system, user })
}

/// Renders the full T2 prompt: system instructions plus the JSON card view.
fn slot_prompt_for(
    state: &AppState,
    at_ms: i64,
    budget_chars: usize,
) -> Result<serde_json::Value, afterray_store::StoreError> {
    let inputs = slot_t2_inputs(state, at_ms, budget_chars)?;
    Ok(serde_json::json!({
        "slot_start_ms": inputs.card.slot_start_ms,
        "slot_end_ms": inputs.card.slot_end_ms,
        "local_day": inputs.card.local_day,
        "state": inputs.card.state,
        "system": inputs.system,
        "user": inputs.user,
    }))
}

/// The slot-scoped tools a T2 agent may call. Every tool reads only this
/// slot's evidence; the summariser has no business elsewhere in the vault.
struct SlotT2Tools<'a> {
    /// Reads only, like every other tool surface.
    store: afterray_store::ReadOnlyVault<'a>,
    card: &'a afterray_store::SlotCard,
}

/// One page of a paginated tool result.
const T2_TOOL_PAGE_CHARS: usize = 3_000;

impl SlotT2Tools<'_> {
    fn get_transcript(&self) -> Result<String, String> {
        let rows = self
            .store
            .transcripts_in_range(self.card.slot_start_ms, self.card.slot_end_ms, 400)
            .map_err(|error| error.to_string())?;
        if rows.is_empty() {
            return Ok("(no speech was recorded in this half hour)".to_owned());
        }
        let mut out = String::new();
        for (at_ms, track, text) in rows {
            let line = format!(
                "{} {}: {}\n",
                afterray_store::slot_clock_label(at_ms),
                track,
                text.trim()
            );
            if out.chars().count() + line.chars().count() > T2_TOOL_PAGE_CHARS {
                out.push_str("…(transcript truncated)\n");
                break;
            }
            out.push_str(&line);
        }
        Ok(out)
    }

    fn get_ocr(&self, args: &serde_json::Value) -> Result<String, String> {
        let id = args
            .get("id")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| "get_ocr requires id (a run id from the input)".to_owned())?;
        // Accept any moment in the slot, not only run anchors: the model may
        // hold an id from a thread citation.
        if !self.card.evidence.moment_ids.iter().any(|held| held == id) {
            return Err(format!("`{id}` is not a frame of this slot"));
        }
        let row = self
            .store
            .ocr_evidence_for_moment(id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("no OCR stored for `{id}`"))?;
        let (text, _layout) = row;
        let clipped: String = text.chars().take(T2_TOOL_PAGE_CHARS).collect();
        Ok(clipped)
    }
}

impl afterray_harness::ToolSurface for SlotT2Tools<'_> {
    async fn invoke(
        &self,
        name: &str,
        args: &serde_json::Value,
    ) -> Result<afterray_harness::Budgeted, String> {
        // Two tools, both answering about evidence the card already stands on.
        // `get_run_text` and `get_prev_cards` are gone: measured, the small
        // models never called either, the large one spent rounds on them, and
        // what they served is now inlined (prev cards) or honestly disclosed
        // and left there (`more_chars`).
        let text = match name {
            "get_transcript" => self.get_transcript(),
            "get_ocr" => self.get_ocr(args),
            other => Err(format!(
                "unknown tool `{other}`; available: get_transcript, get_ocr"
            )),
        }?;
        // These tools already page themselves against `T2_TOOL_PAGE_CHARS`, so
        // there is nothing left for a second budget to cut.
        Ok(afterray_harness::Budgeted::verbatim(text))
    }
}

fn model_library(state: &AppState) -> afterray_protocol::ModelLibrary {
    let mut library = library();
    let download = state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone();
    if let Some(progress) = &download
        && let Some(pack) = library
            .packs
            .iter_mut()
            .find(|pack| pack.id == progress.pack_id)
    {
        pack.state = progress.state;
        pack.error.clone_from(&progress.error);
    }
    for (pack_id, adapter) in &state.mlx_adapters {
        if let Some(pack) = library.packs.iter_mut().find(|pack| pack.id == *pack_id) {
            if let Some(error) = mlx_platform_incompatibility() {
                pack.state = afterray_protocol::ModelPackState::Incompatible;
                pack.error = Some(error.into());
                continue;
            }
            let mlx_health = adapter.health();
            if matches!(
                mlx_health.state,
                afterray_protocol::ModelPackState::Verifying
                    | afterray_protocol::ModelPackState::InUse
                    | afterray_protocol::ModelPackState::Failed
            ) {
                pack.state = mlx_health.state;
                pack.error = mlx_health.error;
            }
        }
    }
    library.download = download;
    library
}

fn mlx_platform_incompatibility() -> Option<&'static str> {
    if !cfg!(target_os = "macos") {
        return Some("AfterRay Local (MLX) requires macOS 14 or later on Apple Silicon");
    }
    if !cfg!(target_arch = "aarch64") {
        return Some("AfterRay Local (MLX) requires Apple Silicon");
    }
    None
}

fn requested_download_packs(
    pack_id: Option<&str>,
    pack_ids: &[String],
) -> Result<Vec<afterray_models::PackSpec>, String> {
    if pack_ids.is_empty() {
        return specs_for_download(pack_id);
    }
    if pack_id.is_some() {
        return Err("provide either `pack_id` or `pack_ids`, not both".into());
    }

    let mut packs = Vec::with_capacity(pack_ids.len());
    for id in pack_ids {
        if packs
            .iter()
            .any(|pack: &afterray_models::PackSpec| pack.id == *id)
        {
            continue;
        }
        let Some(pack) = spec_by_id(id) else {
            return Err(format!("unknown model pack `{id}`"));
        };
        if !pack.inspect().present {
            packs.push(pack);
        }
    }
    Ok(packs)
}

fn start_model_downloads(
    state: &Arc<AppState>,
    pack_id: Option<&str>,
    pack_ids: &[String],
) -> Response {
    let packs = match requested_download_packs(pack_id, pack_ids) {
        Ok(packs) => packs,
        Err(error) => return Response::failure(error),
    };
    if packs.is_empty() {
        return Response::success(model_library(state));
    }

    let starts_worker = state
        .download_active
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok();

    let mut queue = state
        .download_queue
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let current_pack_id = (!starts_worker)
        .then(|| {
            state
                .download
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .map(|progress| progress.pack_id.clone())
        })
        .flatten();
    for pack in packs {
        if current_pack_id.as_ref() == Some(&pack.id)
            || queue.iter().any(|queued| queued.id == pack.id)
        {
            continue;
        }
        queue.push(pack);
    }
    let queued_ids = queue
        .iter()
        .filter(|pack| current_pack_id.as_ref() != Some(&pack.id))
        .map(|pack| pack.id.clone())
        .collect::<Vec<_>>();
    let first = queue.first().cloned();
    drop(queue);

    let mut download = state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if !starts_worker && let Some(progress) = download.as_mut() {
        progress.queued_pack_ids = queued_ids;
    } else if let Some(first) = first {
        let inspected = first.inspect();
        *download = Some(ModelDownloadProgress {
            pack_id: first.id,
            queued_pack_ids: queued_ids,
            state: afterray_protocol::ModelPackState::Downloading,
            bytes: inspected.bytes,
            expected_bytes: Some(first.expected_bytes),
            completed_files: 0,
            total_files: 0,
            error: None,
        });
    }
    drop(download);

    if starts_worker {
        state
            .download_cancel_requested
            .store(false, Ordering::Release);
        state.download_paused.store(false, Ordering::Release);
        let task_state = Arc::clone(state);
        let task = tokio::spawn(async move {
            run_model_downloads(task_state).await;
        });
        state.lifecycle.track_task(task);
    } else if state.download_paused.load(Ordering::Acquire) {
        resume_download_worker(state);
    }
    Response::success(model_library(state))
}

async fn pause_model_downloads(state: &Arc<AppState>) -> Response {
    if !state.download_active.load(Ordering::Acquire) {
        return Response::success(model_library(state));
    }
    state.download_paused.store(true, Ordering::Release);
    if let Some(cancellation) = state
        .download_cancellation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        cancellation.cancel();
    }

    loop {
        let changed = state.download_changed.notified();
        let paused = state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|progress| progress.state == afterray_protocol::ModelPackState::Paused);
        if paused || !state.download_active.load(Ordering::Acquire) {
            break;
        }
        changed.await;
    }
    Response::success(model_library(state))
}

fn resume_model_downloads(state: &Arc<AppState>) -> Response {
    resume_download_worker(state);
    Response::success(model_library(state))
}

fn resume_download_worker(state: &Arc<AppState>) {
    if !state.download_paused.swap(false, Ordering::AcqRel) {
        return;
    }
    if let Some(progress) = state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_mut()
    {
        progress.state = afterray_protocol::ModelPackState::Downloading;
    }
    state.download_changed.notify_waiters();
}

/// True while `pack_id` is the pack the user singled out for cancellation.
fn download_drop_matches(slot: &std::sync::Mutex<Option<String>>, pack_id: &str) -> bool {
    slot.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_deref()
        == Some(pack_id)
}

/// Claims the single-pack cancellation for `pack_id`, clearing it so the worker
/// cannot act on the same request twice.
fn take_download_drop(slot: &std::sync::Mutex<Option<String>>, pack_id: &str) -> bool {
    let mut slot = slot
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if slot.as_deref() == Some(pack_id) {
        *slot = None;
        true
    } else {
        false
    }
}

/// Lifts a not-yet-started pack out of the pending queue.
///
/// Order is load-bearing: the queue is what the app renders, and every waiting
/// row's "starts after the current pack" estimate is the sum of everything
/// ahead of it, so removing one entry must not disturb the others.
fn take_queued_pack(
    queue: &mut Vec<afterray_models::PackSpec>,
    pack_id: &str,
) -> Option<afterray_models::PackSpec> {
    queue
        .iter()
        .position(|queued| queued.id == pack_id)
        .map(|index| queue.remove(index))
}

/// Bins a singly-cancelled pack's partial files and wakes whoever asked for it.
fn finish_dropped_pack(state: &AppState, pack: &afterray_models::PackSpec) {
    if let Err(error) = remove_pack(pack) {
        eprintln!("could not remove cancelled {} download: {error}", pack.name);
    }
    state.download_changed.notify_waiters();
}

fn download_queued_ids(state: &AppState) -> Vec<String> {
    state
        .download_queue
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .iter()
        .map(|queued| queued.id.clone())
        .collect()
}

/// Cancels one pack without disturbing the rest of the queue.
///
/// A pack that has not started yet is simply lifted out of the queue here — the
/// worker never sees it. The pack being downloaded right now has to go through
/// the worker instead, so this only records the request and waits for the worker
/// to acknowledge it; returning earlier would hand the app a snapshot that still
/// lists the pack it just cancelled.
async fn cancel_model_download(state: &Arc<AppState>, pack_id: &str) -> Response {
    if spec_by_id(pack_id).is_none() {
        return Response::failure(format!("unknown model pack `{pack_id}`"));
    }

    let queued_pack = take_queued_pack(
        &mut state
            .download_queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
        pack_id,
    );
    if let Some(pack) = queued_pack {
        if let Err(error) = remove_pack(&pack) {
            eprintln!("could not remove queued {} download: {error}", pack.name);
        }
        let queued_ids = download_queued_ids(state);
        if let Some(progress) = state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_mut()
        {
            progress.queued_pack_ids = queued_ids;
        }
        state.download_changed.notify_waiters();
        return Response::success(model_library(state));
    }

    let is_reported = state
        .download
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|progress| progress.pack_id == pack_id);
    if !is_reported {
        return Response::success(model_library(state));
    }
    if !state.download_active.load(Ordering::Acquire) {
        // A settled failure: the worker is gone and the row only survives so the
        // user can read the error. Cancelling it is how they dismiss it.
        *state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        state.download_changed.notify_waiters();
        return Response::success(model_library(state));
    }

    *state
        .download_drop_pack
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(pack_id.to_owned());
    // A paused pack is parked in the worker's wait loop rather than inside the
    // transfer, so clear the pause too or the drop is never observed.
    state.download_paused.store(false, Ordering::Release);
    if let Some(cancellation) = state
        .download_cancellation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        cancellation.cancel();
    }
    state.download_changed.notify_waiters();

    // `notify_waiters` leaves no permit behind, so a wake that lands between the
    // check and the await would be lost. Re-checking on a short tick keeps this
    // responsive without letting the RPC hang on that race.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let changed = state.download_changed.notified();
        if !download_drop_matches(&state.download_drop_pack, pack_id)
            || !state.download_active.load(Ordering::Acquire)
        {
            break;
        }
        if tokio::time::Instant::now() >= deadline {
            eprintln!("cancel of `{pack_id}` was not acknowledged in time");
            break;
        }
        let _ = tokio::time::timeout(Duration::from_millis(100), changed).await;
    }
    Response::success(model_library(state))
}

async fn cancel_model_downloads(state: &Arc<AppState>) -> Response {
    if !state.download_active.load(Ordering::Acquire) {
        return Response::success(model_library(state));
    }
    state
        .download_cancel_requested
        .store(true, Ordering::Release);
    state.download_paused.store(false, Ordering::Release);
    *state
        .download_drop_pack
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    let queued = state
        .download_queue
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .drain(..)
        .collect::<Vec<_>>();
    for pack in queued {
        if let Err(error) = remove_pack(&pack) {
            eprintln!("could not remove cancelled {} download: {error}", pack.name);
        }
    }
    if let Some(cancellation) = state
        .download_cancellation
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
    {
        cancellation.cancel();
    }
    state.download_changed.notify_waiters();

    while state.download_active.load(Ordering::Acquire) {
        let changed = state.download_changed.notified();
        if !state.download_active.load(Ordering::Acquire) {
            break;
        }
        changed.await;
    }
    Response::success(model_library(state))
}

async fn run_model_downloads(state: Arc<AppState>) {
    loop {
        let pack = {
            let mut queue = state
                .download_queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if queue.is_empty() {
                state.download_active.store(false, Ordering::Release);
                *state
                    .download_cancellation
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
                *state
                    .download
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
                state.download_changed.notify_waiters();
                return;
            }
            queue.remove(0)
        };
        let queued_pack_ids = state
            .download_queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|queued| queued.id.clone())
            .collect::<Vec<_>>();
        let inspected = pack.inspect();
        *state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(ModelDownloadProgress {
            pack_id: pack.id.clone(),
            queued_pack_ids,
            state: afterray_protocol::ModelPackState::Downloading,
            bytes: inspected.bytes,
            expected_bytes: Some(pack.expected_bytes),
            completed_files: 0,
            total_files: 0,
            error: None,
        });

        let cancellation = Cancellation::default();
        *state
            .download_cancellation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(cancellation.clone());
        // Pause/cancel can arrive after the worker claims the queue but before
        // this per-pack cancellation token exists. Re-check the requested
        // state here so those early controls cannot wait forever.
        if state.download_paused.load(Ordering::Acquire)
            || state.download_cancel_requested.load(Ordering::Acquire)
        {
            cancellation.cancel();
        }
        let result = download_packs_with_cancellation(
            std::slice::from_ref(&pack),
            cancellation,
            |spec, progress| {
                let queued_pack_ids = state
                    .download_queue
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .iter()
                    .map(|queued| queued.id.clone())
                    .collect();
                let snapshot = ModelDownloadProgress {
                    pack_id: spec.id.clone(),
                    queued_pack_ids,
                    state: progress.state,
                    bytes: progress.bytes,
                    expected_bytes: progress.expected_bytes,
                    completed_files: u64::try_from(progress.completed_files).unwrap_or(0),
                    total_files: u64::try_from(progress.total_files).unwrap_or(0),
                    error: None,
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
            },
        )
        .await;
        persist_adopted_huggingface_mirror(&state);
        *state
            .download_cancellation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;

        if matches!(result, Err(DownloadError::Cancelled))
            && state
                .download_cancel_requested
                .swap(false, Ordering::AcqRel)
        {
            if let Err(error) = remove_pack(&pack) {
                eprintln!("could not remove cancelled {} download: {error}", pack.name);
            }
            state
                .download_queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
            *state
                .download
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
            state.download_active.store(false, Ordering::Release);
            state.download_changed.notify_waiters();
            return;
        }

        // Dropped on its own: bin this pack's partial files and pick up the
        // next one. Checked before the pause branch because cancelling a paused
        // pack clears the pause flag on its way in.
        if matches!(result, Err(DownloadError::Cancelled))
            && take_download_drop(&state.download_drop_pack, &pack.id)
        {
            finish_dropped_pack(&state, &pack);
            continue;
        }

        if matches!(result, Err(DownloadError::Cancelled))
            && state.download_paused.load(Ordering::Acquire)
        {
            let queued_pack_ids = {
                let mut queue = state
                    .download_queue
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                queue.insert(0, pack.clone());
                queue
                    .iter()
                    .skip(1)
                    .map(|queued| queued.id.clone())
                    .collect()
            };
            if let Some(progress) = state
                .download
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_mut()
            {
                progress.state = afterray_protocol::ModelPackState::Paused;
                progress.queued_pack_ids = queued_pack_ids;
                progress.error = None;
            }
            state.download_changed.notify_waiters();

            loop {
                let changed = state.download_changed.notified();
                if state.download_cancel_requested.load(Ordering::Acquire)
                    || !state.download_paused.load(Ordering::Acquire)
                    || download_drop_matches(&state.download_drop_pack, &pack.id)
                {
                    break;
                }
                changed.await;
            }
            if state
                .download_cancel_requested
                .swap(false, Ordering::AcqRel)
            {
                state
                    .download_queue
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clear();
                *state
                    .download
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
                state.download_active.store(false, Ordering::Release);
                state.download_changed.notify_waiters();
                return;
            }
            // Cancelled while parked. Lift the pack back out of the queue head
            // it was parked in, then let the loop take whatever follows it.
            if take_download_drop(&state.download_drop_pack, &pack.id) {
                {
                    let mut queue = state
                        .download_queue
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if queue.first().is_some_and(|queued| queued.id == pack.id) {
                        queue.remove(0);
                    }
                }
                state.download_paused.store(false, Ordering::Release);
                finish_dropped_pack(&state, &pack);
            }
            continue;
        }

        if let Err(error) = result {
            state
                .download_queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clear();
            let mut progress = state
                .download
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(progress) = progress.as_mut() {
                progress.state = afterray_protocol::ModelPackState::Failed;
                progress.queued_pack_ids.clear();
                progress.error = Some(error.to_string());
            }
            eprintln!("model download failed: {error}");
            state.download_active.store(false, Ordering::Release);
            state.download_changed.notify_waiters();
            return;
        }
        if matches!(pack.id.as_str(), "asr" | "asr_aligner") {
            let pack_id = pack.id.clone();
            let requeued = run_store(&state, move |state| {
                if pack_id == "asr_aligner" {
                    state.store.retry_failed_audio_alignments(now_ms())
                } else {
                    state.store.retry_failed_audio_transcriptions(now_ms())
                }
            })
            .await;
            match requeued {
                Ok(count) if count > 0 => {
                    eprintln!("asr backlog: requeued {count} segment(s) after model repair");
                    state.asr_changed.notify_one();
                }
                Ok(_) => {}
                Err(error) => eprintln!("asr backlog: could not requeue after repair: {error}"),
            }
        }
    }
}

async fn remove_model(state: &Arc<AppState>, pack_id: &str) -> Response {
    let Some(pack) = spec_by_id(pack_id) else {
        return Response::failure(format!("unknown model pack `{pack_id}`"));
    };
    if state.download_active.load(Ordering::Acquire)
        && state
            .download
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_some_and(|progress| {
                progress.pack_id == pack_id
                    || progress
                        .queued_pack_ids
                        .iter()
                        .any(|queued| queued == pack_id)
            })
    {
        return Response::failure(format!("model pack `{pack_id}` is currently downloading"));
    }
    if let Some((_, adapter)) = state.mlx_adapters.iter().find(|(id, _)| id == pack_id) {
        adapter.shutdown().await;
    }
    match remove_pack(&pack) {
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
        "gop packer: enabled keyint={} cold_gop_only",
        state.packer.config.policy.keyint
    );
    let lifecycle_state = Arc::clone(&state);
    match std::thread::Builder::new()
        .name("gop-packer".into())
        .spawn(move || {
            apply_background_qos();
            eprintln!("gop packer: background thread started");
            if thread_sleep_until_draining(&state, Duration::from_secs(15)) {
                return;
            }
            let mut blocked_reason: Option<String> = None;
            loop {
                if state.draining.load(Ordering::Acquire) {
                    break;
                }
                // rav1e is the only all-core workload here, so it is the one a
                // user most wants to stand down. Checked before the vault is
                // touched; `pack_one` keeps its own AC check as a backstop.
                if let Err(refusal) = state.compute.decide(
                    afterray_protocol::ComputeWorkload::Archive,
                    compute::MachineConditions::probe(),
                    now_ms(),
                ) {
                    if blocked_reason.as_deref() != Some(refusal.reason.as_str()) {
                        eprintln!("gop packer: holding off — {}", refusal.reason);
                        blocked_reason = Some(refusal.reason);
                    }
                    // Ten seconds, not a minute: this is also how long "run now"
                    // takes to visibly start, and the probes it re-reads are
                    // cheap.
                    if thread_sleep_until_draining(&state, Duration::from_secs(10)) {
                        break;
                    }
                    continue;
                }
                if blocked_reason.take().is_some() {
                    eprintln!("gop packer: resuming");
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
                    if thread_sleep_until_draining(&state, Duration::from_secs(1)) {
                        break;
                    }
                    continue;
                }
                match state.packer.pack_one(&state.store, now_ms()) {
                    Ok(Some(segment_id)) => {
                        eprintln!("gop packer: committed {segment_id}");
                    }
                    Ok(None) => {
                        // Nothing left to pack, so a "run now" override has done
                        // its job and the usual power gates should apply again.
                        if state
                            .compute
                            .clear_force(afterray_protocol::ComputeWorkload::Archive)
                        {
                            eprintln!("gop packer: nothing left to pack, override ended");
                        }
                    }
                    Err(error) => eprintln!("gop packer: {error:#}"),
                }
                if thread_sleep_until_draining(&state, Duration::from_secs(5)) {
                    break;
                }
            }
        }) {
        Ok(thread) => lifecycle_state.lifecycle.track_thread(thread),
        Err(error) => eprintln!("gop packer: failed to spawn background thread: {error}"),
    }
}

fn thread_sleep_until_draining(state: &AppState, duration: Duration) -> bool {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if state.draining.load(Ordering::Acquire) {
            return true;
        }
        std::thread::sleep(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(100)),
        );
    }
    state.draining.load(Ordering::Acquire)
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

/// Drop AAC that sits at measured digital silence (~1.3 kbps for an idle
/// 5-minute system track). The shim writes 300s segments at 96 kbps when
/// there is speech; averaging that against minutes of silence must not
/// look like "no speech" — 20s of talk in a 5-minute file is ~6.4 kbps.
/// Short clips are never dropped.
fn is_near_silent_audio(byte_len: usize, started_at_ms: i64, ended_at_ms: i64) -> bool {
    const SILENCE_BPS: u128 = 2_000;
    let duration_ms = ended_at_ms.saturating_sub(started_at_ms);
    if duration_ms < 30_000 {
        return false;
    }
    let bits = u128::try_from(byte_len)
        .unwrap_or(u128::MAX)
        .saturating_mul(8);
    let bps = bits.saturating_mul(1000) / u128::try_from(duration_ms).unwrap_or(1);
    bps < SILENCE_BPS
}

fn pack_status(state: &AppState) -> Response {
    match state.store.pack_status_counts() {
        Ok(counts) => Response::success(PackStatus {
            archive_enabled: state.packer.config.archive,
            keep_stills: false,
            keyint: state.packer.config.policy.keyint,
            encoder: "rav1e".to_owned(),
            hot_window_seconds: u64::try_from(state.packer.config.policy.hot_window_ms / 1000)
                .unwrap_or(7200),
            running_jobs: counts.running,
            done_jobs: counts.done,
            failed_jobs: counts.failed,
            ready_segments: counts.ready,
            ready_frames: counts.ready_frames,
            one_frame_segments: counts.one_frame_segments,
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

    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn required_shutdown_work_is_not_cut_off_by_disposable_deadlines() {
        let completed = Arc::new(AtomicBool::new(false));
        let completed_after_close = Arc::clone(&completed);
        let started = Instant::now();

        let (memory_flushed, session_closed) = tokio::time::timeout(
            Duration::from_secs(6),
            finish_required_recording_close(async { "memory flushed" }, async move {
                // This stands in for slow vault maintenance plus
                // end_session_sync after the active session was taken. It
                // deliberately exceeds the retired four-second aggregate
                // timeout: required close must still run to completion.
                tokio::time::sleep(Duration::from_millis(4_100)).await;
                completed_after_close.store(true, Ordering::Release);
                "session closed"
            }),
        )
        .await
        .expect("the test guard should not expire");

        assert_eq!(memory_flushed, "memory flushed");
        assert_eq!(session_closed, "session closed");
        assert!(completed.load(Ordering::Acquire));
        assert!(started.elapsed() >= Duration::from_secs(4));
    }

    #[tokio::test]
    async fn graceful_stopped_drains_slow_final_artifact_before_session_close() {
        let (events_tx, events_rx) = tokio::sync::mpsc::channel(2);
        let events_rx = Arc::new(tokio::sync::Mutex::new(events_rx));
        let import_completed = Arc::new(AtomicBool::new(false));
        let session_closed = Arc::new(AtomicBool::new(false));
        let imported_by_consumer = Arc::clone(&import_completed);
        let closed_seen_by_consumer = Arc::clone(&session_closed);
        let receiver = Arc::clone(&events_rx);
        let consumer = tokio::spawn(consume_capture_event_stream(
            move || {
                let receiver = Arc::clone(&receiver);
                async move { receiver.lock().await.recv().await }
            },
            move |event| {
                let imported_by_consumer = Arc::clone(&imported_by_consumer);
                let closed_seen_by_consumer = Arc::clone(&closed_seen_by_consumer);
                async move {
                    match event {
                        CaptureEvent::Artifact { .. } => {
                            // Model a final vault import held behind slow disk I/O
                            // for longer than the retired one-second drain budget.
                            tokio::time::sleep(Duration::from_millis(1_200)).await;
                            assert!(!closed_seen_by_consumer.load(Ordering::Acquire));
                            imported_by_consumer.store(true, Ordering::Release);
                        }
                        other => panic!("unexpected non-terminal test event: {other:?}"),
                    }
                }
            },
            || async { panic!("graceful test stream must not fail") },
        ));

        events_tx
            .send(Ok(CaptureEvent::Artifact {
                kind: ArtifactKind::Screen,
                path: PathBuf::from("final-frame.jpg"),
                content_type: "image/jpeg".to_owned(),
                started_at_ms: 1,
                ended_at_ms: 1,
                byte_count: 1,
                request_id: Some("final-frame".to_owned()),
            }))
            .await
            .unwrap();
        events_tx.send(Ok(CaptureEvent::Stopped)).await.unwrap();
        drop(events_tx);

        let imported_before_close = Arc::clone(&import_completed);
        let closed_by_session = Arc::clone(&session_closed);
        let (consumer_error, memory_flushed, session_result) = tokio::time::timeout(
            Duration::from_secs(3),
            finish_recording_after_helper_stop(
                Some(consumer),
                false,
                "test graceful stop",
                async { "memory flushed" },
                async move {
                    assert!(imported_before_close.load(Ordering::Acquire));
                    closed_by_session.store(true, Ordering::Release);
                    Ok::<(), String>(())
                },
            ),
        )
        .await
        .expect("a finite graceful stream must drain");

        assert_eq!(consumer_error, None);
        assert_eq!(memory_flushed, "memory flushed");
        assert_eq!(session_result, Ok(()));
        assert!(import_completed.load(Ordering::Acquire));
        assert!(session_closed.load(Ordering::Acquire));
    }

    #[tokio::test]
    async fn failed_helper_consumer_keeps_the_short_recovery_boundary() {
        let consumer = tokio::spawn(std::future::pending::<CaptureConsumerOutcome>());
        let started = Instant::now();

        let error = drain_capture_consumer(Some(consumer), true, "test failed stop")
            .await
            .expect("a stuck failed-helper consumer must time out");

        assert_eq!(error, "capture event consumer timed out");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stop_failure_and_wake_start_cannot_cross_capture_generations() {
        use std::os::unix::fs::PermissionsExt as _;

        let temporary = tempfile::tempdir().unwrap();
        let shim = temporary.path().join("stop-failure-wake-shim.sh");
        std::fs::write(
            &shim,
            "#!/bin/sh\nIFS= read -r line\nprintf '%s\\n' '{\"event\":\"ready\",\"display_id\":1,\"width\":100,\"height\":100}'\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *capture_screen*) printf '%s\\n' '{\"event\":\"failed\",\"code\":\"stream_stopped\",\"message\":\"display went away\"}' ;;\n    *stop*)\n      printf '%s\\n' '{\"event\":\"artifact\",\"kind\":\"system_audio\",\"path\":\"/tmp/final.m4a\",\"content_type\":\"audio/mp4\",\"started_at_ms\":1,\"ended_at_ms\":2,\"byte_count\":3}'\n      printf '%s\\n' '{\"event\":\"stopped\"}'\n      exit 0\n      ;;\n  esac\ndone\n",
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            MacOsCaptureBackend::new(CaptureConfig::new(&shim, temporary.path().join("capture")));

        backend.start_capture().await.unwrap();
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(5), backend.next_event()).await,
            Ok(Some(Ok(CaptureEvent::Ready { .. })))
        ));
        backend.capture_screen("trigger-failure").await.unwrap();

        let (artifact_seen_tx, artifact_seen_rx) = tokio::sync::oneshot::channel();
        let (finish_old_tx, finish_old_rx) = tokio::sync::oneshot::channel();
        let consumer_backend = Arc::clone(&backend);
        let old_consumer = tokio::spawn(async move {
            let mut seen = Vec::new();
            let mut artifact_seen_tx = Some(artifact_seen_tx);
            let mut finish_old_rx = Some(finish_old_rx);
            loop {
                let event = consumer_backend
                    .next_event()
                    .await
                    .expect("old generation should reach its terminal failure")
                    .expect("old generation should emit protocol events");
                match event {
                    CaptureEvent::Artifact { .. } => {
                        seen.push("artifact");
                        artifact_seen_tx
                            .take()
                            .expect("only one tail artifact is expected")
                            .send(())
                            .unwrap();
                        finish_old_rx
                            .take()
                            .expect("only one tail artifact is expected")
                            .await
                            .unwrap();
                    }
                    CaptureEvent::Failed { .. } => {
                        seen.push("failed");
                        break;
                    }
                    other => panic!("unexpected old-generation event: {other:?}"),
                }
            }
            seen
        });

        let lifecycle = Arc::new(CaptureLifecycle::default());
        let old_finished = Arc::new(AtomicBool::new(false));
        let (idle_tx, idle_rx) = tokio::sync::oneshot::channel();
        let stop_lifecycle = Arc::clone(&lifecycle);
        let stop_backend = Arc::clone(&backend);
        let stop_finished = Arc::clone(&old_finished);
        let stop = tokio::spawn(async move {
            let _gate = stop_lifecycle.enter().await;
            idle_tx.send(()).unwrap();
            let _ = stop_backend.stop_capture().await;
            let seen = old_consumer.await.expect("old consumer should not panic");
            let discarded = stop_backend.discard_stopped_generation_events().await;
            stop_finished.store(true, Ordering::Release);
            (seen, discarded)
        });

        let wake_lifecycle = Arc::clone(&lifecycle);
        let wake_backend = Arc::clone(&backend);
        let wake_seen_stop = Arc::clone(&old_finished);
        let (wake_attempted_tx, wake_attempted_rx) = tokio::sync::oneshot::channel();
        let (wake_entered_tx, mut wake_entered_rx) = tokio::sync::oneshot::channel();
        let wake = tokio::spawn(async move {
            idle_rx.await.unwrap();
            wake_attempted_tx.send(()).unwrap();
            let _gate = wake_lifecycle.enter().await;
            let _ = wake_entered_tx.send(());
            assert!(
                wake_seen_stop.load(Ordering::Acquire),
                "wake-side start entered before the old consumer finished"
            );
            wake_backend.start_capture().await.unwrap();
            wake_backend.next_event().await
        });

        artifact_seen_rx.await.unwrap();
        wake_attempted_rx.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), &mut wake_entered_rx)
                .await
                .is_err(),
            "wake-side start entered while the old consumer still held its tail"
        );
        finish_old_tx.send(()).unwrap();

        let (stop, wake) =
            tokio::time::timeout(Duration::from_secs(10), async { tokio::join!(stop, wake) })
                .await
                .expect("stop/failure/wake sequence must stay bounded");
        wake_entered_rx.await.unwrap();
        let (seen, discarded) = stop.expect("stop task should not panic");
        assert_eq!(seen, vec!["artifact", "failed"]);
        assert_eq!(discarded, 0);
        assert!(matches!(
            wake.expect("wake task should not panic"),
            Some(Ok(CaptureEvent::Ready { .. }))
        ));

        let _ = backend.stop_capture().await;
        backend.discard_stopped_generation_events().await;
    }

    #[tokio::test]
    async fn background_lifecycle_reaps_completed_tasks_and_joins_cancelled_tasks() {
        let lifecycle = BackgroundLifecycle::default();
        for _ in 0..500 {
            lifecycle.track_task(tokio::spawn(async {
                tokio::task::yield_now().await;
            }));
        }

        let remaining = lifecycle
            .wait_for_tasks_until(Instant::now() + Duration::from_secs(2))
            .await;
        assert_eq!(remaining, 0);
        assert_eq!(lifecycle.active_task_count(), 0);

        lifecycle.track_task(tokio::spawn(std::future::pending()));
        assert_eq!(lifecycle.active_task_count(), 1);
        lifecycle.cancel_and_join(Duration::from_millis(250)).await;
        assert_eq!(lifecycle.active_task_count(), 0);
    }

    #[test]
    fn unexpected_capture_eof_takes_the_failed_recording_path() {
        assert_eq!(
            capture_stream_disposition(&Err(CaptureError::UnexpectedEof)),
            CaptureStreamDisposition::Failed
        );
        assert_eq!(
            capture_stream_disposition(&Ok(CaptureEvent::Stopped)),
            CaptureStreamDisposition::Stopped
        );
    }

    #[tokio::test]
    async fn shutdown_ack_is_fully_written_before_draining_starts() {
        let (mut client, mut server) = tokio::io::duplex(1);
        let draining = Arc::new(AtomicBool::new(false));
        let triggered = Arc::clone(&draining);
        let ack = tokio::spawn(async move {
            acknowledge_shutdown(&mut server, || triggered.store(true, Ordering::Release)).await
        });

        // One byte of capacity cannot hold the JSON ACK. With nobody reading,
        // write_all must still be suspended and the drain signal must stay off.
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!draining.load(Ordering::Acquire));

        let mut response = Vec::new();
        client.read_to_end(&mut response).await.unwrap();
        ack.await.unwrap().unwrap();
        assert!(draining.load(Ordering::Acquire));
        let response: Response = serde_json::from_slice(&response).unwrap();
        assert!(response.ok);
        assert_eq!(response.data.unwrap()["stopping"], true);
    }

    #[test]
    fn near_silent_audio_drops_long_quiet_tracks_but_keeps_speech() {
        // 48 KB over 5 minutes ≈ 1.3 kbps (idle system track).
        assert!(is_near_silent_audio(48 * 1024, 0, 300_000));
        // 2 MB over 5 minutes ≈ 53 kbps (mic with room tone / speech).
        assert!(!is_near_silent_audio(2 * 1024 * 1024, 0, 300_000));
        // A one-second utterance is small but real — never drop short clips.
        assert!(!is_near_silent_audio(8 * 1024, 0, 1_000));
        // 20s of 96 kbps speech + 280s idle in one 5-minute file ≈ 6.4 kbps.
        let twenty_seconds_talk = 20 * 96_000 / 8;
        assert!(!is_near_silent_audio(twenty_seconds_talk, 0, 300_000));
    }

    /// T2 used to plan against `ContextBudget::DEFAULT` while chat measured the
    /// real window: on a 256k model the summariser wrote from a twelfth of the
    /// context it had, and nothing in the logs said so. Now both derive from
    /// the same probe — bounded below by the constant this replaced, and above
    /// by what has actually been evaluated.
    #[test]
    fn the_t2_prompt_budget_follows_the_window_between_a_floor_and_a_ceiling() {
        let for_window = |tokens: usize| {
            t2_prompt_budget_chars(ContextBudget {
                max_rounds: T2_MAX_ROUNDS,
                ..ContextBudget::for_window(tokens)
            })
        };

        // A small window buys fewer rounds, never a card written from scraps.
        assert_eq!(for_window(4_096), T2_PROMPT_FLOOR_CHARS);
        assert_eq!(for_window(16_384), T2_PROMPT_FLOOR_CHARS);
        let large = for_window(131_072);
        assert!(
            large > T2_PROMPT_FLOOR_CHARS && large < T2_PROMPT_CEILING_CHARS,
            "a real window must move the budget: {large}"
        );
        assert_eq!(for_window(262_144), T2_PROMPT_CEILING_CHARS);
        // Monotone: a bigger window is never a smaller prompt.
        assert!(for_window(65_536) <= large);
        // And whatever it derives still fits the turn it was derived from.
        assert!(
            ContextBudget {
                max_rounds: T2_MAX_ROUNDS,
                ..ContextBudget::for_window(131_072)
            }
            .is_coherent()
        );
    }

    /// The import path for an R3 edge snapshot is fail-closed: it stores the
    /// tree only when the snapshot names the app it came from, because that name
    /// is the only thing the exclusion list can be checked against.
    #[test]
    fn an_edge_snapshot_is_only_storable_once_it_names_its_app() {
        assert_eq!(edge_snapshot_identity(b"not json at all"), None);
        assert_eq!(edge_snapshot_identity(b"{}"), None, "parsed but unnamed");
        assert_eq!(
            edge_snapshot_identity(br#"{"application_name":"Safari"}"#),
            None,
            "a display name is not an exclusion key"
        );
        assert_eq!(
            edge_snapshot_identity(
                br#"{"bundle_identifier":"com.electron.lark","window_title":"Lody Team","root":{}}"#
            ),
            Some(("com.electron.lark".to_owned(), None))
        );
        assert_eq!(
            edge_snapshot_identity(
                br#"{"bundle_identifier":"com.apple.Safari","url":"https://example.com/x"}"#
            ),
            Some((
                "com.apple.Safari".to_owned(),
                Some("https://example.com/x".to_owned())
            )),
            "the URL must reach the domain exclusion check"
        );
    }

    /// The screenshot throttle, as the decision it is: an input batch may pull
    /// a frame forward, but never closer than the plan's 10s floor and never
    /// denser than the heartbeat the user configured.
    #[test]
    fn an_input_batch_pulls_a_frame_forward_only_past_the_throttle() {
        let default_ms = 10_000;

        // Nothing happened: the heartbeat's phase is all there is.
        assert!(!event_capture_is_due(0, 0, 60_000, default_ms));
        assert!(!event_capture_is_due(0, 0, i64::MAX, default_ms));

        // The common case, at the interval's own boundary and past it.
        assert!(event_capture_is_due(1, 50_000, 60_000, default_ms));
        assert!(event_capture_is_due(7, 50_000, 61_000, default_ms));
        assert!(!event_capture_is_due(7, 50_000, 59_999, default_ms));

        // A user who asked for fewer frames gets fewer frames: the throttle
        // never drops below the configured cadence.
        assert!(!event_capture_is_due(1, 50_000, 65_000, 60_000));
        assert!(event_capture_is_due(1, 50_000, 110_000, 60_000));

        // And a user who asked for more does not get the event path firing
        // faster than the plan's floor.
        assert!(!event_capture_is_due(1, 50_000, 53_000, 2_000));
        assert!(event_capture_is_due(1, 50_000, 60_000, 2_000));

        // Nothing captured yet — a fresh session, or one just stopped and
        // restarted — is past any throttle, whatever the clock reads.
        assert!(event_capture_is_due(1, 0, 1_000, default_ms));
        assert!(event_capture_is_due(1, 0, 0, 60_000));
        // ...but "nothing" still needs an event to justify a frame.
        assert!(!event_capture_is_due(0, 0, 1_000, default_ms));
    }

    /// Every field of a v2 record has to land somewhere in the row, and the
    /// target has to keep arriving verbatim: `value`, `secure` and `subrole`
    /// ride the platform crate's own `Serialize` into `target_json`, so nothing
    /// here re-models element identity and nothing silently drops when the shim
    /// adds a key.
    #[test]
    fn a_v2_record_maps_content_to_columns_and_the_rest_to_one_object() {
        let burst: InputEventRecord = serde_json::from_str(
            r#"{"at_ms":1000,"end_ms":4000,"kind":"burst","count":17,
                "ended_with":"return","bundle_identifier":"com.electron.lark",
                "text":"wsm tongyini",
                "target":{"role":"AXTextField","subrole":"AXSearchField",
                          "label":"Message","value":"我们什么时候同意的",
                          "secure":false}}"#,
        )
        .unwrap();
        let row = input_event_row(&burst);
        assert_eq!(row.text.as_deref(), Some("wsm tongyini"));
        assert_eq!(row.extra_json, None, "a burst names no extra field");
        let target: serde_json::Value =
            serde_json::from_str(row.target_json.as_deref().unwrap()).unwrap();
        assert_eq!(target["value"], "我们什么时候同意的");
        assert_eq!(target["secure"], false);
        assert_eq!(target["subrole"], "AXSearchField");

        let drag: InputEventRecord = serde_json::from_str(
            r#"{"at_ms":5000,"kind":"drag","bundle_identifier":"com.apple.finder",
                "source":{"label":"0817.log"},
                "destination":{"label":"Archive"}}"#,
        )
        .unwrap();
        let extra: serde_json::Value =
            serde_json::from_str(input_event_extra_json(&drag).unwrap().as_str()).unwrap();
        assert_eq!(extra["source"]["label"], "0817.log");
        assert_eq!(extra["destination"]["label"], "Archive");
        assert_eq!(extra.as_object().unwrap().len(), 2, "no null keys");

        let switched: InputEventRecord = serde_json::from_str(
            r#"{"at_ms":6000,"kind":"window_changed","bundle_identifier":"dev.zed.Zed",
                "application_name":"Zed","window_title":"lib.rs"}"#,
        )
        .unwrap();
        assert_eq!(
            input_event_extra_json(&switched).as_deref(),
            Some(r#"{"application_name":"Zed","window_title":"lib.rs"}"#)
        );

        // A pre-v2 batch still parses, and adds nothing.
        let old: InputEventRecord =
            serde_json::from_str(r#"{"at_ms":7000,"kind":"click"}"#).unwrap();
        let row = input_event_row(&old);
        assert_eq!(
            (row.text, row.extra_json, row.target_json),
            (None, None, None)
        );
    }

    /// The sweeper log is where somebody goes to answer "how long did that
    /// take", so it must not make them convert milliseconds in their head — and
    /// it must render a duration exactly as the panel does (`ComputeFormat`
    /// `duration(ms:)`), or the same pass reads as two different numbers.
    #[test]
    fn logged_durations_are_readable_at_every_scale() {
        assert_eq!(human_duration(Duration::from_millis(940)), "0s");
        assert_eq!(human_duration(Duration::from_millis(9_500)), "9s");
        assert_eq!(human_duration(Duration::from_secs(61)), "1m 01s");
        assert_eq!(human_duration(Duration::from_secs(161)), "2m 41s");
        assert_eq!(human_duration(Duration::from_secs(3_600)), "1h 00m");
        assert_eq!(human_duration(Duration::from_secs(4_500)), "1h 15m");
    }

    /// The picker's list and the vault's accepted lengths are declared in two
    /// crates that cannot see each other — the protocol must not depend on the
    /// vault. This is the seam where they are checked to agree; without it the
    /// app can offer a length every save then rejects.
    #[test]
    fn every_offered_summary_length_is_one_the_vault_accepts() {
        let offered = afterray_protocol::summary_slot_minutes_options();
        for minutes in &offered {
            assert!(
                afterray_store::slot_duration_ms_for_minutes(i64::from(*minutes)).is_some(),
                "the settings UI offers {minutes} minutes, which the vault rejects"
            );
        }
        let accepted: Vec<u32> = afterray_store::SLOT_DURATION_CHOICES_MINUTES
            .iter()
            .map(|minutes| u32::try_from(*minutes).expect("positive minute count"))
            .collect();
        assert_eq!(offered, accepted);
        assert!(offered.contains(&afterray_protocol::DEFAULT_SUMMARY_SLOT_MINUTES));
        assert_eq!(
            i64::from(afterray_protocol::DEFAULT_SUMMARY_SLOT_MINUTES) * 60_000,
            afterray_store::CURRENT_SLOT_DURATION_MS
        );
    }

    #[test]
    fn model_download_request_rejects_ambiguous_or_unknown_pack_ids() {
        let ambiguous =
            requested_download_packs(Some("asr"), &["embedding".to_owned()]).unwrap_err();
        assert!(ambiguous.contains("either `pack_id` or `pack_ids`"));

        let unknown = requested_download_packs(None, &["not-a-model".to_owned()]).unwrap_err();
        assert!(unknown.contains("unknown model pack `not-a-model`"));
    }

    /// Cancelling one waiting pack must not reshuffle the others: the app draws
    /// the queue in this order and estimates each row from everything above it.
    #[test]
    fn cancelling_a_queued_pack_leaves_the_rest_of_the_queue_in_order() {
        let ids = ["asr", "embedding", QWEN35_4B_MLX_PACK_ID];
        let mut queue = ids
            .iter()
            .map(|id| spec_by_id(id).expect("catalog pack"))
            .collect::<Vec<_>>();

        let taken = take_queued_pack(&mut queue, "embedding").expect("embedding was queued");

        assert_eq!(taken.id, "embedding");
        let remaining = queue
            .iter()
            .map(|pack| pack.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(remaining, ["asr", QWEN35_4B_MLX_PACK_ID]);
        assert!(take_queued_pack(&mut queue, "embedding").is_none());
        assert!(take_queued_pack(&mut queue, "not-a-model").is_none());
    }

    /// The worker acts on the drop flag once and clears it. A second read must
    /// not fire, or resuming the queue would bin the pack that came next.
    #[test]
    fn a_single_pack_cancellation_is_claimed_exactly_once() {
        let slot = std::sync::Mutex::new(Some("asr".to_owned()));

        assert!(download_drop_matches(&slot, "asr"));
        assert!(!download_drop_matches(&slot, "embedding"));
        assert!(
            !take_download_drop(&slot, "embedding"),
            "a different pack must not claim the cancellation"
        );

        assert!(take_download_drop(&slot, "asr"));
        assert!(!take_download_drop(&slot, "asr"), "claimed twice");
        assert!(!download_drop_matches(&slot, "asr"));
        assert!(slot.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn a_bound_socket_is_private_to_its_owner() {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("nested").join("afterray.sock");
        let (listener, uid) = bind_control_socket(&socket).unwrap();

        let mode = std::fs::metadata(&socket).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "socket mode {mode:o}");
        let parent_mode = std::fs::metadata(socket.parent().unwrap())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(parent_mode & 0o777, 0o700, "directory mode {parent_mode:o}");
        assert_eq!(
            uid,
            std::fs::metadata(&socket).unwrap().uid(),
            "the reported owner has to be the uid that bound the socket"
        );
        drop(listener);

        // A directory other users can enter is tightened before the socket
        // lands in it.
        let shared = directory.path().join("shared");
        std::fs::create_dir(&shared).unwrap();
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
        let (listener, _) = bind_control_socket(&shared.join("afterray.sock")).unwrap();
        let shared_mode = std::fs::metadata(&shared).unwrap().permissions().mode();
        assert_eq!(shared_mode & 0o777, 0o700, "shared mode {shared_mode:o}");
        drop(listener);
    }

    #[tokio::test]
    async fn a_live_daemon_is_never_evicted_from_its_socket() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("afterray.sock");
        let (listener, _) = bind_control_socket(&socket).unwrap();

        let error = bind_control_socket(&socket).unwrap_err().to_string();
        assert!(error.contains("already listening"), "{error}");
        drop(listener);

        // The dead socket left behind is ours to reclaim.
        bind_control_socket(&socket).unwrap();
    }

    /// Unlinking whatever sits at the path was the old behaviour. A regular
    /// file or a symlink there is a sign something else owns the name, and
    /// following it would let that thing pick what we destroy.
    #[tokio::test]
    async fn a_path_that_is_not_our_socket_is_left_alone() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("afterray.sock");
        std::fs::write(&socket, b"not a socket").unwrap();
        let error = bind_control_socket(&socket).unwrap_err().to_string();
        assert!(error.contains("not a socket"), "{error}");
        assert!(socket.exists(), "the file must survive the refusal");

        let linked = directory.path().join("linked.sock");
        std::os::unix::fs::symlink(&socket, &linked).unwrap();
        let error = bind_control_socket(&linked).unwrap_err().to_string();
        assert!(error.contains("not a socket"), "{error}");
        assert!(socket.exists(), "the symlink target must survive too");
    }

    #[test]
    fn cli_evidence_persists_before_memory_and_rolls_back_on_io_error() {
        let directory = tempfile::tempdir().unwrap();
        let slot = std::sync::Mutex::new(None);
        persist_then_store_cli_evidence(
            directory.path(),
            PersistedSettings::default(),
            &slot,
            Some(42),
        )
        .unwrap();
        assert_eq!(*slot.lock().unwrap(), Some(42));
        assert_eq!(
            load_persisted_settings(directory.path()).cli_evidence_until_ms,
            Some(42)
        );

        let blocked = directory.path().join("blocked");
        std::fs::write(&blocked, b"not-a-directory").unwrap();
        let err = persist_then_store_cli_evidence(
            &blocked,
            PersistedSettings {
                cli_evidence_until_ms: Some(42),
                ..PersistedSettings::default()
            },
            &slot,
            None,
        )
        .unwrap_err();
        assert!(!err.to_string().is_empty());
        assert_eq!(
            *slot.lock().unwrap(),
            Some(42),
            "a failed persist must not change the live window"
        );
        assert_eq!(
            load_persisted_settings(directory.path()).cli_evidence_until_ms,
            Some(42),
            "the last good settings.json must survive the failed write"
        );
    }

    #[test]
    fn settings_are_written_private_and_never_carry_the_api_key() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let settings = PersistedSettings {
            legacy_llm_api_key: "sk-must-not-be-written".to_owned(),
            ..PersistedSettings::default()
        };
        save_persisted_settings(directory.path(), &settings).unwrap();

        let path = settings_path(directory.path());
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "settings mode {mode:o}");
        let written = std::fs::read_to_string(&path).unwrap();
        assert!(!written.contains("sk-must-not-be-written"), "{written}");
        assert!(!written.contains("llm_api_key"), "{written}");
    }

    #[test]
    fn protected_credential_apps_are_enforced_without_polluting_user_exclusions() {
        let normalized = normalize_bundle_ids(vec!["com.apple.Safari".to_owned()]);
        assert_eq!(normalized, ["com.apple.Safari"]);
        for protected in PROTECTED_BUNDLE_IDS {
            assert!(is_protected_bundle(protected));
            assert!(!normalized.iter().any(|id| id == protected));
        }
        assert!(is_protected_bundle("COM.BITWARDEN.DESKTOP"));
    }

    #[test]
    fn existing_settings_drop_the_legacy_seeded_protected_catalogue() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(
            settings_path(directory.path()),
            br#"{"excluded_bundle_ids":["com.apple.Safari","com.bitwarden.desktop","com.apple.Passwords"]}"#,
        )
        .unwrap();

        let settings = load_persisted_settings(directory.path());
        assert!(
            settings
                .excluded_bundle_ids
                .iter()
                .any(|id| id == "com.apple.Safari")
        );
        assert!(
            !settings
                .excluded_bundle_ids
                .iter()
                .any(|id| is_protected_bundle(id))
        );
    }

    /// The endpoint must survive a daemon restart and default to empty (the
    /// official huggingface.co) on files written before the field existed.
    #[test]
    fn download_endpoint_round_trips_and_defaults_to_official() {
        let directory = tempfile::tempdir().unwrap();
        let settings = PersistedSettings {
            model_download_endpoint: "https://hf-mirror.com".to_owned(),
            ..PersistedSettings::default()
        };
        save_persisted_settings(directory.path(), &settings).unwrap();
        let reloaded = load_persisted_settings(directory.path());
        assert_eq!(reloaded.model_download_endpoint, "https://hf-mirror.com");

        std::fs::write(settings_path(directory.path()), br#"{"record_audio":true}"#).unwrap();
        let legacy = load_persisted_settings(directory.path());
        assert!(legacy.model_download_endpoint.is_empty());
    }

    /// The field is gone from what we write but has to survive what we read,
    /// or a user upgrading from V0 silently loses their configured key.
    #[test]
    fn a_settings_file_from_before_the_keychain_still_yields_its_key() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(
            settings_path(directory.path()),
            br#"{"llm_api_key":"sk-legacy","llm_model":"gpt-4o-mini"}"#,
        )
        .unwrap();
        let persisted = load_persisted_settings(directory.path());
        assert_eq!(persisted.legacy_llm_api_key, "sk-legacy");
        assert_eq!(persisted.llm_model, "gpt-4o-mini");
    }

    /// People paste what is in the address bar. Every one of these means the
    /// same site, and rejecting any of them produces an exclusion that looks
    /// saved and silently never fires.
    #[test]
    fn a_domain_is_recognised_however_it_was_typed() {
        for input in [
            "example.com",
            "  example.com  ",
            "EXAMPLE.com",
            "https://example.com",
            "https://example.com/",
            "http://example.com/inbox?q=1#top",
            "example.com:8443",
            "https://user:pw@example.com/path",
            "example.com.",
        ] {
            assert_eq!(
                normalize_domain(input).as_deref(),
                Some("example.com"),
                "{input}"
            );
        }
    }

    /// Settings saved against the retired built-in provider decode as the
    /// local MLX path. Any chat model id left over from that era is not a
    /// managed pack, so it must be dropped rather than left to fail the route.
    #[test]
    fn settings_from_the_retired_builtin_provider_land_on_the_recommended_pack() {
        let persisted = PersistedSettings {
            llm_model: "qwen3.6:latest".to_owned(),
            ..PersistedSettings::default()
        };
        let config = resolve_llm_config(&persisted);
        assert_eq!(config.provider, LlmProvider::MlxLocal);
        assert!(config.model.is_empty());
        assert_eq!(
            config.mlx_pack_id(),
            Some(afterray_models::QWEN35_4B_MLX_PACK_ID)
        );
    }

    /// A bare word is a typo, not a host. Storing it would leave a row in the
    /// list that can never match anything.
    #[test]
    fn things_that_are_not_hosts_are_rejected() {
        for input in ["", "   ", "localhost", "https://", "/", "just some text"] {
            assert_eq!(normalize_domain(input), None, "{input}");
        }
    }

    /// Excluding a site has to cover its subdomains, or the promise is false:
    /// most of what a user wants hidden lives on `mail.` or `app.`.
    #[test]
    fn excluding_a_domain_covers_its_subdomains() {
        assert!(host_matches_domain("example.com", "example.com"));
        assert!(host_matches_domain("mail.example.com", "example.com"));
        assert!(host_matches_domain("a.b.example.com", "example.com"));
    }

    /// And must not reach past the dot. `notexample.com` is somebody else's
    /// site, and a suffix test written with `ends_with` alone would eat it.
    #[test]
    fn excluding_a_domain_stops_at_the_label_boundary() {
        assert!(!host_matches_domain("notexample.com", "example.com"));
        assert!(!host_matches_domain("example.com.evil.test", "example.com"));
        assert!(!host_matches_domain("example.co", "example.com"));
        // The narrower entry must not be widened by the broader one.
        assert!(!host_matches_domain("example.com", "mail.example.com"));
    }

    #[test]
    fn the_saved_list_is_deduplicated_and_ordered() {
        let cleaned = normalize_domains(vec![
            "https://example.com/inbox".into(),
            "EXAMPLE.COM".into(),
            "  ".into(),
            "bank.test".into(),
            "not a host".into(),
        ]);
        assert_eq!(
            cleaned,
            vec!["bank.test".to_owned(), "example.com".to_owned()]
        );
    }

    fn day_slot(start_ms: i64, state: SlotSummaryState) -> afterray_store::DaySlot {
        afterray_store::DaySlot {
            slot_start_ms: start_ms,
            slot_end_ms: start_ms + afterray_store::SLOT_DURATION_MS,
            state,
            anchor_moment_id: None,
            facts: afterray_store::SlotFacts {
                apps: Vec::new(),
                top_windows: Vec::new(),
                top_documents: Vec::new(),
                top_urls: Vec::new(),
                has_audio: false,
                audio_moment_count: 0,
                moment_count: 12,
                ocr_moment_count: 0,
                ax_moment_count: 0,
                switch_count: 0,
                longest_focus_ms: 0,
                idle_ratio: 0.0,
                no_input_ratio: None,
            },
            title: None,
            bullets: None,
            category: None,
            details: None,
            description: None,
            threads: None,
            entities: None,
            decisions: None,
            not_captured: None,
        }
    }

    /// The selection rule carries each slot's end now (the ASR gate needs it);
    /// these three tests are about which slots come back, so they read starts.
    fn due_slot_starts(slots: &[afterray_store::DaySlot], now: i64) -> Vec<i64> {
        due_slot_windows(slots, now)
            .into_iter()
            .map(|(slot_start_ms, _)| slot_start_ms)
            .collect()
    }

    /// The daemon can be off, or on battery, for longer than the events live.
    /// When it comes back the slot is still `Degraded` and long past settle, so
    /// every other gate would wave it through — and it would be summarised from
    /// screen text alone, with nothing to mark the card as having been written
    /// without the record of what the user did. A missing card says that; a
    /// half-sourced one does not, and cards are never revised.
    #[test]
    fn a_slot_whose_events_have_expired_is_never_summarised() {
        let base = 1_700_000_000_000;
        let expired =
            base - afterray_store::RAW_EVENT_RETENTION_MS - 2 * afterray_store::SLOT_DURATION_MS;
        let live = base - 10 * afterray_store::SLOT_DURATION_MS;
        let slots = [
            day_slot(expired, SlotSummaryState::Degraded),
            day_slot(live, SlotSummaryState::Degraded),
        ];

        assert_eq!(
            due_slot_starts(&slots, base),
            vec![live],
            "the expired slot is dropped, the live one is still due"
        );
    }

    /// The cutoff keeps the instant itself, matching `prune_input_events_before`.
    /// A slot ending exactly on it still has its events.
    #[test]
    fn a_slot_ending_on_the_expiry_cutoff_is_still_summarised() {
        let base = 1_700_000_000_000;
        let cutoff = base - afterray_store::RAW_EVENT_RETENTION_MS;
        let start = cutoff - afterray_store::SLOT_DURATION_MS;
        let slots = [day_slot(start, SlotSummaryState::Degraded)];

        assert_eq!(due_slot_starts(&slots, base), vec![start]);
    }

    /// Everything except `Degraded` is either already summarised, deliberately
    /// skipped, or has nothing to summarise. Picking any of them up would mean
    /// re-running the model over work it already did.
    #[test]
    fn only_degraded_slots_are_swept() {
        let base = 1_700_000_000_000;
        let long_ago = base - 10 * afterray_store::SLOT_DURATION_MS;
        let slots = [
            day_slot(long_ago, SlotSummaryState::Degraded),
            day_slot(long_ago + 60_000, SlotSummaryState::Done),
            day_slot(long_ago + 120_000, SlotSummaryState::SkippedIdle),
            day_slot(long_ago + 180_000, SlotSummaryState::NoData),
            day_slot(long_ago + 240_000, SlotSummaryState::Failed),
        ];
        assert_eq!(due_slot_starts(&slots, base), vec![long_ago]);
    }

    /// A slot is not eligible the instant it closes: frames captured near the
    /// boundary are still landing, and summarising then reads a partial slot.
    #[test]
    fn a_slot_waits_out_the_settle_window() {
        let start = 1_700_000_000_000;
        let end = start + afterray_store::SLOT_DURATION_MS;
        let slots = [day_slot(start, SlotSummaryState::Degraded)];

        assert!(
            due_slot_starts(&slots, end).is_empty(),
            "closed but not settled"
        );
        assert!(
            due_slot_starts(&slots, end + T2_SETTLE_MS - 1).is_empty(),
            "one millisecond short still counts as unsettled"
        );
        assert_eq!(due_slot_starts(&slots, end + T2_SETTLE_MS), vec![start]);
    }

    /// The slot the user is inside right now has not closed at all.
    #[test]
    fn the_slot_in_progress_is_never_swept() {
        let start = 1_700_000_000_000;
        let slots = [day_slot(start, SlotSummaryState::Degraded)];
        let midway = start + afterray_store::SLOT_DURATION_MS / 2;
        assert!(due_slot_starts(&slots, midway).is_empty());
    }

    /// ASR that transcribed something a minute ago and has failed nothing.
    fn healthy_asr(now: i64) -> AsrHealth {
        AsrHealth {
            last_success_ms: Some(now - 60_000),
            last_failure_ms: None,
            waiting_segments: 1,
            exhausted_segments: 0,
        }
    }

    #[test]
    fn a_slot_with_nothing_pending_never_waits() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        assert_eq!(
            asr_wait_verdict(&healthy_asr(now), false, slot_end, now),
            AsrWait::Proceed(AsrProceed::NoTranscriptPending),
        );
    }

    /// The whole point: a card that would otherwise say "the transcript was
    /// unavailable" — permanently, because a written card is never re-run —
    /// while the transcript was minutes away.
    #[test]
    fn a_slot_holds_back_while_a_live_asr_still_owes_it_a_transcript() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        assert_eq!(
            asr_wait_verdict(&healthy_asr(now), true, slot_end, now),
            AsrWait::Wait,
        );
    }

    /// Freshness is measured against the last *failure*, not the clock. A
    /// machine that slept eight hours wakes with an eight-hour-old success and
    /// a perfectly healthy worker; judging that dead would drop the wait on
    /// exactly the first meeting after the lid opens.
    #[test]
    fn sleeping_does_not_make_a_healthy_asr_look_dead() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        let slept = AsrHealth {
            last_success_ms: Some(now - 8 * 60 * 60 * 1000),
            ..healthy_asr(now)
        };
        assert_eq!(asr_wait_verdict(&slept, true, slot_end, now), AsrWait::Wait);

        // A long weekend, too — the wall clock is only ever a backstop.
        let weekend = AsrHealth {
            last_success_ms: Some(now - 3 * 24 * 60 * 60 * 1000),
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&weekend, true, slot_end, now),
            AsrWait::Wait
        );
    }

    /// The failure an unconditional wait would produce: a machine where the
    /// model was never downloaded would hold every audio-bearing card forever.
    #[test]
    fn asr_that_never_succeeded_holds_nothing_back() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        let cold = AsrHealth {
            last_success_ms: None,
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&cold, true, slot_end, now),
            AsrWait::Proceed(AsrProceed::NeverSucceeded),
        );
    }

    #[test]
    fn asr_failing_more_recently_than_it_succeeds_holds_nothing_back() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        let broken = AsrHealth {
            last_success_ms: Some(now - 60 * 60 * 1000),
            last_failure_ms: Some(now - 30 * 1000),
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&broken, true, slot_end, now),
            AsrWait::Proceed(AsrProceed::FailingNotSucceeding),
        );
        // The other order is the ordinary one: a failure, then a recovery.
        let recovered = AsrHealth {
            last_success_ms: Some(now - 30 * 1000),
            last_failure_ms: Some(now - 60 * 60 * 1000),
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&recovered, true, slot_end, now),
            AsrWait::Wait
        );
    }

    /// The only case wall-clock staleness can see: a worker that stopped
    /// succeeding without recording a failure, because nothing claims and so
    /// nothing fails.
    #[test]
    fn an_ancient_success_holds_nothing_back() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        let abandoned = AsrHealth {
            last_success_ms: Some(now - ASR_ALIVE_STALENESS_MS - 1),
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&abandoned, true, slot_end, now),
            AsrWait::Proceed(AsrProceed::SuccessTooStale),
        );
    }

    #[test]
    fn a_pile_that_has_run_its_backoff_out_holds_nothing_back() {
        let now = 1_700_000_000_000;
        let slot_end = now - 4 * 60 * 1000;
        let stuck = AsrHealth {
            waiting_segments: 3,
            exhausted_segments: 3,
            ..healthy_asr(now)
        };
        assert_eq!(
            asr_wait_verdict(&stuck, true, slot_end, now),
            AsrWait::Proceed(AsrProceed::AllPendingExhausted),
        );
        let partly = AsrHealth {
            exhausted_segments: 2,
            ..stuck
        };
        assert_eq!(
            asr_wait_verdict(&partly, true, slot_end, now),
            AsrWait::Wait
        );
    }

    /// Measured: a ten-job backlog is about fifty minutes of audio, so the cap
    /// is reachable and must expire. Past it the card arrives honestly
    /// incomplete rather than never arriving at all.
    #[test]
    fn the_wait_expires_at_the_cap() {
        let now = 1_700_000_000_000;
        let slot_end = now - ASR_WAIT_CAP_MS;
        assert_eq!(
            asr_wait_verdict(&healthy_asr(now), true, slot_end, now),
            AsrWait::Proceed(AsrProceed::CapElapsed),
        );
        assert_eq!(
            asr_wait_verdict(&healthy_asr(now), true, slot_end + 1, now),
            AsrWait::Wait,
            "one millisecond inside the cap is still worth waiting for"
        );
    }

    /// A vault with real audio in it, end to end: the sweeper holds the slot
    /// back while its transcript is coming, `slot backfill` does not, and the
    /// slot stays `Degraded` throughout — waiting is "skip this round", not a
    /// state transition, and `Degraded` is the only state the sweeper ever
    /// picks back up.
    #[test]
    fn the_sweeper_waits_for_a_transcript_and_backfill_does_not() {
        let (_directory, vault) = test_vault();
        let base = 1_786_698_000_000_i64;
        let session = vault.create_session_sync(base).unwrap();
        for (index, offset) in [0_i64, 20_000, 40_000].into_iter().enumerate() {
            let moment = vault
                .insert_moment(&session.id, base + offset, "image/jpeg", b"screen")
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    &format!("cargo test -p afterrayd, run {index}"),
                    base + offset,
                    None,
                    "test-ocr",
                    None,
                )
                .unwrap();
        }
        let interval_ms = 10_000;
        let settled = base + afterray_store::SLOT_DURATION_MS + T2_SETTLE_MS + 60_000;
        let windows = slot_windows_awaiting_t2(&vault, interval_ms, settled, 1);
        assert_eq!(windows.len(), 1, "one degraded slot to summarise");
        let (slot_start_ms, slot_end_ms) = windows[0];

        // ASR is alive: something transcribed successfully a minute ago.
        let elsewhere = vault
            .insert_audio_segment(
                &session.id,
                afterray_protocol::AudioTrack::System,
                slot_start_ms - 3_600_000,
                slot_start_ms - 3_500_000,
                "audio/mp4",
                b"earlier",
            )
            .unwrap();
        vault
            .complete_audio_transcription(
                &elsewhere,
                "an earlier meeting",
                Some("English"),
                "test-asr",
                settled - 60_000,
            )
            .unwrap();
        // …and this slot's own audio has not been transcribed yet.
        let pending = vault
            .insert_audio_segment(
                &session.id,
                afterray_protocol::AudioTrack::Microphone,
                slot_start_ms + 1_000,
                slot_end_ms - 1_000,
                "audio/mp4",
                b"the meeting",
            )
            .unwrap();

        let swept = slots_ready_for_t2(&vault, interval_ms, settled, 1);
        assert!(swept.ready.is_empty(), "the transcript is still coming");
        assert_eq!(swept.waiting_on_asr, 1);
        assert_eq!(
            slots_awaiting_t2(&vault, interval_ms, settled, 1),
            vec![slot_start_ms],
            "backfill is an explicit request to fill history and never waits"
        );
        let day = vault.day_summary(settled, interval_ms).unwrap();
        assert_eq!(
            day.slots
                .iter()
                .find(|slot| slot.slot_start_ms == slot_start_ms)
                .map(|slot| slot.state),
            Some(SlotSummaryState::Degraded),
            "waiting is skipping a round, not a state change"
        );

        // The transcript lands: the slot is swept on the next round.
        vault
            .complete_audio_transcription(
                &pending,
                "we agreed to ship on Friday",
                Some("English"),
                "test-asr",
                settled,
            )
            .unwrap();
        assert_eq!(
            slots_ready_for_t2(&vault, interval_ms, settled, 1).ready,
            vec![slot_start_ms],
        );
    }

    #[test]
    fn alignment_language_prefers_asr_metadata_then_infers_old_transcripts() {
        assert_eq!(alignment_language_or_infer(Some("fr"), "ignored"), "fr");
        assert_eq!(alignment_language_or_infer(None, "你好。"), "Chinese");
        assert_eq!(
            alignment_language_or_infer(None, "こんにちは。"),
            "Japanese"
        );
        assert_eq!(alignment_language_or_infer(None, "안녕하세요."), "Korean");
        assert_eq!(alignment_language_or_infer(None, "Hello."), "English");
    }

    #[test]
    fn alignment_cues_are_bounded_to_the_exact_vault_segment() {
        let cue = |ordinal, text: &str, start_offset_ms, end_offset_ms| TranscriptCue {
            ordinal,
            text: text.into(),
            start_offset_ms,
            end_offset_ms,
            timing_kind: afterray_protocol::TranscriptTimingKind::Aligned,
        };
        let bounded = bound_alignment_cues_to_segment(
            vec![cue(4, "First", 100, 900), cue(5, "second", 900, 1_080)],
            1_000,
        )
        .unwrap();
        assert_eq!(bounded.len(), 2);
        assert_eq!(bounded[0].ordinal, 0);
        assert_eq!(bounded[1].ordinal, 1);
        assert_eq!(bounded[1].text, "second");
        assert_eq!(bounded[1].start_offset_ms, 900);
        assert_eq!(bounded[1].end_offset_ms, 1_000);
    }

    #[test]
    fn alignment_cues_reject_false_retiming() {
        let cue = |ordinal, text: &str, start_offset_ms, end_offset_ms| TranscriptCue {
            ordinal,
            text: text.into(),
            start_offset_ms,
            end_offset_ms,
            timing_kind: afterray_protocol::TranscriptTimingKind::Aligned,
        };
        assert!(
            bound_alignment_cues_to_segment(
                vec![cue(0, "First", 100, 900), cue(1, "overlap", 850, 950)],
                1_000,
            )
            .is_err()
        );
        assert!(
            bound_alignment_cues_to_segment(vec![cue(0, "outside", 1_000, 1_100)], 1_000).is_err()
        );
        assert!(bound_alignment_cues_to_segment(Vec::new(), 1_000).is_err());
    }

    /// Past the cap the same vault stops waiting — otherwise a machine whose
    /// ASR is merely slow would go quiet instead of late.
    #[test]
    fn the_sweeper_gives_up_on_a_transcript_after_the_cap() {
        let (_directory, vault) = test_vault();
        let base = 1_786_698_000_000_i64;
        let session = vault.create_session_sync(base).unwrap();
        for (index, offset) in [0_i64, 20_000, 40_000].into_iter().enumerate() {
            let moment = vault
                .insert_moment(&session.id, base + offset, "image/jpeg", b"screen")
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    &format!("cargo test -p afterrayd, run {index}"),
                    base + offset,
                    None,
                    "test-ocr",
                    None,
                )
                .unwrap();
        }
        let interval_ms = 10_000;
        let settled = base + afterray_store::SLOT_DURATION_MS + T2_SETTLE_MS + 60_000;
        let (slot_start_ms, slot_end_ms) =
            slot_windows_awaiting_t2(&vault, interval_ms, settled, 1)[0];
        let alive = vault
            .insert_audio_segment(
                &session.id,
                afterray_protocol::AudioTrack::System,
                slot_start_ms - 3_600_000,
                slot_start_ms - 3_500_000,
                "audio/mp4",
                b"earlier",
            )
            .unwrap();
        vault
            .insert_audio_segment(
                &session.id,
                afterray_protocol::AudioTrack::Microphone,
                slot_start_ms + 1_000,
                slot_end_ms - 1_000,
                "audio/mp4",
                b"the meeting",
            )
            .unwrap();
        let expired = slot_end_ms + ASR_WAIT_CAP_MS;
        vault
            .complete_audio_transcription(
                &alive,
                "an earlier meeting",
                Some("English"),
                "test-asr",
                expired - 60_000,
            )
            .unwrap();
        assert_eq!(
            slots_ready_for_t2(&vault, interval_ms, expired, 1).ready,
            vec![slot_start_ms],
        );
    }

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

    #[test]
    fn legacy_settings_default_to_one_hundred_gigabytes() {
        let settings: PersistedSettings =
            serde_json::from_str(r#"{"record_audio":false}"#).unwrap();
        assert_eq!(settings.storage_limit_bytes, DEFAULT_STORAGE_LIMIT_BYTES);
    }

    fn test_vault() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
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
        let (jpegs, _) = load_e2e_jpegs();
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

    #[test]
    fn agent_search_is_exact_text_only() {
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

        let hits = search_hits(
            afterray_store::ReadOnlyVault::new(&vault),
            "needle",
            &afterray_store::SearchFilter::default(),
            10,
        )
        .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].text, "needle in local memory");
    }

    /// The narrowing that used to happen after ranking, and therefore did not
    /// work: the vault holds the same word in two months, the ranking prefers
    /// the recent one, and a question about the older month came back empty
    /// while its evidence sat in the vault.
    #[test]
    fn a_narrowed_search_reaches_evidence_the_ranking_would_have_buried() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let july = 1_783_000_000_000_i64;
        let august = 1_786_000_000_000_i64;
        for (at_ms, text) in [
            (july, "lody notes from july"),
            (august, "lody notes from august"),
            (august + 1, "lody again in august"),
            (august + 2, "lody once more in august"),
        ] {
            vault
                .insert_text_evidence(
                    &session.id,
                    None,
                    None,
                    "ocr",
                    text,
                    at_ms,
                    None,
                    "ocr-model",
                    None,
                )
                .unwrap();
        }

        // One result, and the ranking alone would not have chosen July's.
        let hits = search_hits(
            afterray_store::ReadOnlyVault::new(&vault),
            "lody",
            &afterray_store::SearchFilter::range(Some(july - 1), Some(july + 1)),
            1,
        )
        .unwrap();
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].text, "lody notes from july");
    }

    /// The recall UI reads this path, and a hit it shows is a hit it promises
    /// to highlight. A neighbour in embedding space has no such pixels.
    #[test]
    fn ui_search_is_exact_text_only() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let evidence = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "conceptual local context",
                1,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        vault
            .insert_embedding(&evidence, &[1.0, 0.0], "test-embedding")
            .unwrap();

        assert!(text_hits(&vault, "needle", 10).unwrap().is_empty());
        assert_eq!(text_hits(&vault, "conceptual", 10).unwrap().len(), 1);
    }

    /// Embeddings are switched off, and this is the assertion that they stay
    /// off until the redesign lands: `Vault::semantic_search` reads every
    /// stored vector out of `SQLite` as JSON and scores it in Rust, which
    /// measures 683 ms over a week of capture and grows linearly.
    ///
    /// Written against the source rather than behaviour, because the failure
    /// this guards against is someone re-adding the call, not a wrong answer.
    #[test]
    fn nothing_in_the_daemon_computes_or_stores_an_embedding() {
        let production = include_str!("main.rs")
            .split_once("\n#[cfg(test)]")
            .map_or(include_str!("main.rs"), |(before, _)| before);
        for needle in [
            concat!("semantic_", "search("),
            concat!("insert_", "embedding("),
            concat!("ModelInput::", "Embedding"),
        ] {
            assert!(
                !production.contains(needle),
                "`{needle}` is back. Embedding retrieval has no index; see the \
                 redesign before wiring it up again."
            );
        }
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

    /// Frames for the packer e2e, and whether they are real screen captures.
    ///
    /// The two sources are not interchangeable. Sampled captures are what the
    /// archive actually holds — a near-static screen with a small change per
    /// frame, which is the whole reason a closed GOP pays. The ffmpeg fallback
    /// is four 64×64 solid-colour frames so the test can run at all on a
    /// machine without the sample directory, and it cannot carry a compression
    /// claim: measured here, 32 bytes of IVF file header plus 12 per frame are
    /// 37% of the 218-byte output, against JPEGs that are themselves mostly
    /// JFIF and quantisation tables. What the ratio reports there is container
    /// overhead, not the codec.
    fn load_e2e_jpegs() -> (Vec<Vec<u8>>, bool) {
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
            return (
                files
                    .into_iter()
                    .take(take)
                    .map(|path| std::fs::read(path).unwrap())
                    .collect(),
                true,
            );
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
                return (Vec::new(), false);
            }
            frames.push(std::fs::read(path).unwrap());
        }
        (frames, false)
    }

    #[test]
    fn packer_encodes_closed_gop_and_serves_poster() {
        let (jpegs, from_real_captures) = load_e2e_jpegs();
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
        // The 5x claim belongs to real captures, and is asserted only against
        // them. On screen-like frames it is not a close call — 2560x1440 with
        // a small change per frame measures 48x — so a real sample landing
        // near this line means something changed, which is what a threshold is
        // for. Holding the synthetic fallback to it only ever reported that
        // 64x64 solid colour has nothing to compress.
        if from_real_captures {
            assert!(
                ratio < 0.20,
                "GOP should beat 5x vs JPEG, got {:.1}%",
                ratio * 100.0
            );
        } else {
            assert!(
                ratio < 1.0,
                "even four toy frames must not grow when packed, got {:.1}%",
                ratio * 100.0
            );
        }
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
            policy: policy.clone(),
        });
        let mut packed = 0_usize;
        let mut ivf_bytes = 0_usize;
        let mut jpeg_bytes = 0_usize;
        let mut multi_frame = None;
        for _ in 0..max_segments {
            let candidates = vault.list_pack_candidates(now, &policy).unwrap();
            let Some(run) =
                afterray_store::first_packable_run(afterray_store::fold_pack_runs(&candidates, 12))
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
