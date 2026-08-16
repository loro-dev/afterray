# AGENTS.md — afterray-models

The model-layer hub for `afterrayd`: an in-memory priority-aware job queue (`ModelQueue`), the `ModelAdapter` trait + typed `ModelInput`/`ModelOutput` contract, the SHA-256-pinned model catalog/downloads, the one-shot and persistent-MLX worker protocols, and the LLM router (`mlx_local` / `ollama` / `openai_compatible`). Never writes results to SQLite — the daemon commits typed outputs through `afterray-store`. See `README.md` for the full tour.

## Key files

- `src/lib.rs` — `ModelCapability` (`:51`); `ModelInput` (`:73`) / `ModelOutput` (`:124`), serde `tag="type"`, snake_case; `OcrRegion` (`:112`) — Apple Vision bottom-left origin, screen consumers must flip Y; `ModelAdapter` trait (`:221`); `AdapterError` (`:195`) with `retryable()` (`:215` — only `Process`/`Io`/`Timeout` retry).
- `src/queue.rs` — `ModelQueue` (`:299`, in-memory by design); `CapabilityConcurrency` (`:40`); `JobPriority` (`:106`); `LlmGate` (`:131`, LLM-only priority admission); `hold_llm_lease()` (`:351`) RAII lane reservation.
- `src/process.rs` — one-shot protocol: `WORKER_PROTOCOL_VERSION = 1` (`:7`); `ProcessAdapter` (`:64`): one child per inference, one JSON request on stdin, one JSON response on stdout, stderr = logs only; 300s timeout, 16 MiB stdout cap.
- `src/persistent_mlx.rs` — `MLX_WORKER_PROTOCOL_VERSION = 1` (`:17`); `PersistentMlxAdapter` (`:69`): NDJSON, `load`/`generate`/`cancel` → `ready`/`delta`/`final`/`cancelled`/`error`; `verify_model` (`:274`) re-checks the pinned manifest + ready marker before every spawn; `normalize_model_output` (`:530`) strips `<think>`/control tokens.
- `src/remote.rs` — `LlmRouterAdapter` (`:127`) routes LLM jobs to a per-pack MLX adapter or Ollama/OpenAI-compatible HTTP; `check_origin` (`:484`) allows https or loopback-http only; reqwest clients disable redirects so prompts/API keys can't leak to a redirect target.
- `src/catalog.rs` — pack specs; `READY_MARKER` (`:4`); pinned MLX revisions + SHA-256 manifests (`QWEN35_4B/9B_MLX_REVISION`); `model_directory()` (`:97`, `AFTERRAY_MODEL_DIR` override).
- `src/download.rs` — pure-Rust/reqwest downloads; `.partial` resume + `<name>.download/` staging, SHA-256 `verify_files`, atomic rename. Never half-populate `pack.path`. Endpoint order: settings (`set_huggingface_endpoint`, fed by the daemon) → `HF_ENDPOINT` env → huggingface.co; proxies come from env vars + macOS system settings via reqwest's `system-proxy` feature — root `Cargo.toml` must keep that feature or every request silently goes direct.

## Invariants

- Worker stdout is protocol-only — a stray print kills the job as `InvalidOutput` (pinned by `rejects_non_json_stdout`, `persistent_mlx.rs:738`). Logs go to stderr.
- Workers signal failures via `retryable` in `WorkerResponse`: `true` → `AdapterError::Process` (retried), `false` → `MissingModel` (`process.rs:180`). Never fabricate inference output; fail with an actionable `MissingModel`.
- LLM lane fairness: background submitters must use `JobPriority::Background{..}`; multi-round agent loops must take `hold_llm_lease()` and pass the lease id, or every round re-queues behind rivals (measured 8-minute stalls, `queue.rs:104`).
- Pinned MLX snapshots are verified three times: at download, at spawn, and inside the Swift worker. Revision constants live in both `catalog.rs` and `swift/AfterRayMlxVlmWorker/Sources/WorkerCore.swift` — change together; bump `MLX_WORKER_PROTOCOL_VERSION` in lockstep with the Swift `mlxWorkerProtocolVersion`.
- **Every pack is SHA-256-pinned**, which is what makes download mirrors safe: MLX via `HuggingFacePinnedSnapshot`, asr via `SnapshotPin` on `HuggingFaceSnapshot`, embedding via `sha256` on `HuggingFaceFile` (plain layout, no ready marker — installed packs stay valid). To bump a revision: LFS hashes come from the HF tree API (`lfs.oid`); small non-LFS files must be fetched at that commit and hashed by hand. An `AFTERRAY_*` repo override drops the pin — custom content is knowingly unverified.
- `LlmRuntimeConfig::mlx_pack_id()` (`remote.rs:61`) accepts only the managed pack ids, never free-form paths.

## Watch out

- `worker_adapters()` (`src/lib.rs:238`) is a legacy catch-all; the daemon wires per-capability adapters itself (`afterrayd/src/main.rs:316`). Don't copy the pattern.
- The old `llm` GGUF assistant pack is retired; a catalog test enforces that no pack with capability `llm` returns. LLM is MLX-local or remote only.
- `scripts/download-models/*.py` are dead code — downloads are Rust/reqwest only; the daemon never launches Python.

## Build / test

- `cargo test -p afterray-models`; `cargo clippy -p afterray-models --all-targets -- -D warnings`.
- `make models` downloads packs (via `cargo run -p afterray-cli --release -- download`).
