# AGENTS.md — afterray-models

The model-layer hub for `afterrayd`: an in-memory priority-aware job queue (`ModelQueue`), the `ModelAdapter` trait + typed `ModelInput`/`ModelOutput` contract, the SHA-256-pinned model catalog/downloads, the one-shot and persistent-MLX worker protocols, and the LLM router (`mlx_local` / `ollama` / `openai_compatible`). Never writes results to SQLite — the daemon commits typed outputs through `afterray-store`. See `README.md` for the full tour.

## Key files

- `src/lib.rs` — `ModelCapability` (`:51`); `ModelInput` (`:73`) / `ModelOutput` (`:124`), serde `tag="type"`, snake_case; `OcrRegion` (`:112`) — Apple Vision bottom-left origin, screen consumers must flip Y; `ModelAdapter` trait (`:221`); `AdapterError` (`:195`) with `retryable()` (`:215` — only `Process`/`Io`/`Timeout` retry).
- `src/queue.rs` — `ModelQueue` (`:299`, in-memory by design); `CapabilityConcurrency` (`:40`); `JobPriority` (`:106`); `LlmGate` (`:131`, LLM-only priority admission); `hold_llm_lease()` (`:351`) RAII lane reservation; `activity()` → `QueueActivity` (what the compute dashboard polls — never `list()`, which carries every job's output); `prune_terminal` caps finished jobs at 200 outside a 60s grace window `wait()` depends on.
- `src/process.rs` — one-shot protocol: `WORKER_PROTOCOL_VERSION = 1` (`:7`); `ProcessAdapter` (`:64`): one child per inference, one JSON request on stdin, one JSON response on stdout, stderr = logs only; 300s timeout, 16 MiB stdout cap.
- `src/persistent_mlx.rs` — `MLX_WORKER_PROTOCOL_VERSION = 1` (`:17`); `PersistentMlxAdapter` (`:69`): NDJSON, `load`/`generate`/`cancel` → `ready`/`delta`/`final`/`cancelled`/`error`; `verify_model` (`:274`) re-checks the pinned manifest + ready marker before every spawn; `normalize_model_output` (`:530`) strips `<think>`/control tokens.
- `src/remote.rs` — `LlmRouterAdapter` routes LLM jobs to a per-pack MLX adapter or Ollama/OpenAI-compatible HTTP. `ModelInput::Llm.temperature` overrides sampling per remote task (Ollama `options.temperature`, OpenAI-compatible top-level `temperature`); managed MLX stays deterministic. `check_origin` allows HTTPS or loopback HTTP only, and reqwest disables redirects so prompts/API keys cannot leak to a redirect target. Loopback origins must bypass proxies (`without_proxy_for_loopback`, `client_for`): an empty `NO_PROXY=` still wins reqwest's lookup and can otherwise send 127.0.0.1 to a proxy. Remote generation uses a 2s connect timeout, 15m time-to-first-byte, and 180s between chunks — never a total request timeout (`stream.rs`).

- `src/catalog.rs` — pack specs; `READY_MARKER` (`:4`); pinned MLX revisions + SHA-256 manifests (`QWEN35_4B/9B_MLX_REVISION`); `model_directory()` (`:97`, `AFTERRAY_MODEL_DIR` override).
- `src/asr_pack.rs` — the shared Qwen3-ASR readiness contract: deterministically builds the upstream snapshot's omitted `tokenizer.json`, validates that it loads, and binds it to the pinned input manifest with `.afterray-ready.json`.
- `src/download.rs` — pure-Rust/reqwest downloads; `.partial` resume + `<name>.download/` staging, SHA-256 `verify_files`, atomic rename. Never half-populate `pack.path`. `reclaim_abandoned_downloads` only deletes `*.download` **directories** whose newest file is older than 24h; the daemon runs it **once at startup**, never on `model_library`. Installed pack dirs are a different name and cannot match. Endpoint order: settings (`set_huggingface_endpoint`, fed by the daemon) → `HF_ENDPOINT` env → huggingface.co; proxies come from env vars + macOS system settings via reqwest's `system-proxy` feature — root `Cargo.toml` must keep that feature or every request silently goes direct.

## Invariants

- `ModelAdapter::worker_pid(job_id)` is the only route from a running job to a pid, and so to an honest per-task cost; adapters with no child answer `None` rather than something plausible ([why](../../context/compute-governance.md)).
- Worker stdout is protocol-only — a stray print kills the job as `InvalidOutput` (pinned by `rejects_non_json_stdout`, `persistent_mlx.rs:738`). Logs go to stderr.
- Workers signal failures via `retryable` in `WorkerResponse`: `true` → `AdapterError::Process` (retried), `false` → `MissingModel` (`process.rs:180`). Never fabricate inference output; fail with an actionable `MissingModel`.
- LLM lane fairness: background submitters must use `JobPriority::Background{..}`; multi-round agent loops must take `hold_llm_lease()` and pass the lease id, or every round re-queues behind rivals (measured 8-minute stalls, `queue.rs:104`).
- Pinned MLX snapshots are verified three times: at download, at spawn, and inside the Swift worker. Revision constants live in both `catalog.rs` and `swift/AfterRayMlxVlmWorker/Sources/WorkerCore.swift` — change together; bump `MLX_WORKER_PROTOCOL_VERSION` in lockstep with the Swift `mlxWorkerProtocolVersion`.
- **Every pack is SHA-256-pinned**, which is what makes download mirrors safe: MLX via `HuggingFacePinnedSnapshot`, asr via `SnapshotPin` on `HuggingFaceSnapshot`, embedding via `sha256` on `HuggingFaceFile` (plain layout, no ready marker — installed packs stay valid). To bump a revision: LFS hashes come from the HF tree API (`lfs.oid`); small non-LFS files must be fetched at that commit and hashed by hand. An `AFTERRAY_*` repo override drops the pin — custom content is knowingly unverified.
- ASR is `Ready` only after `prepare_qwen3_asr` has generated and parsed `tokenizer.json`; catalog inspection, downloads, and the inference worker share that verifier. A worker load failure invalidates the marker instead of retrying a deterministic broken pack.
- `LlmRuntimeConfig::mlx_pack_id()` (`remote.rs:61`) accepts only the managed pack ids, never free-form paths.

## Watch out

- `worker_adapters()` (`src/lib.rs:238`) is a legacy catch-all; the daemon wires per-capability adapters itself (`afterrayd/src/main.rs:316`). Don't copy the pattern.
- The old `llm` GGUF assistant pack is retired; a catalog test enforces that no pack with capability `llm` returns. LLM is MLX-local or remote only.
- `scripts/download-models/*.py` are dead code — downloads are Rust/reqwest only; the daemon never launches Python.

## Build / test

- `cargo test -p afterray-models`; `cargo clippy -p afterray-models --all-targets -- -D warnings`.
- `make models` downloads packs (via `cargo run -p afterray-cli --release -- download`).
