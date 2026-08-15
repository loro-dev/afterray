# AGENTS.md — apps/AfterRayMlxVlmWorker

The persistent MLX VLM worker executable (root `Package.swift` target, product `afterray-mlx-vlm-worker`), launched and supervised by the Rust daemon (`crates/afterray-models`). `Sources/main.swift` here is only a 12-line stdin loop over `MlxWorker`; all logic lives in the shared `AfterRayMlxVlmWorkerCore` target at `swift/AfterRayMlxVlmWorker/Sources/WorkerCore.swift` so tests can import it. Edit the core, not this shell.

## Protocol (line-delimited JSON, v1)

- `mlxWorkerProtocolVersion = 1` (`WorkerCore.swift:8`); requests `load`/`generate`/`cancel`, responses `ready`/`delta`/`final`/`cancelled`/`error`, every response echoes `request_id`
- Must stay in sync with the Rust side: `MLX_WORKER_PROTOCOL_VERSION` in `crates/afterray-models/src/persistent_mlx.rs:17`
- stdout is protocol-only (`ProtocolWriter`, `WorkerCore.swift:65`); logging goes to stderr via `WorkerLog` (:84)

## Invariants (WorkerCore.swift)

- Single-flight: one generate at a time (:116); never ack `cancel` until the MLX task has actually stopped (:151, the Qwen3.5 KV-cache regression shape)
- Generation runs at temperature 0 (:181) with `enable_thinking: false` (:196); strip `<think>`/control tokens via `normalizeModelOutput` (:219)
- KV-cache session reuse only when system instructions are unchanged and `use_kv_cache` is true (:33)
- `validateLocalSnapshot` (:347) requires the `.afterray-ready.json` marker with a pinned revision (`qwen35_4BRevision`/`qwen35_9BRevision`, :10-11 — keep in sync with `crates/afterray-models/src/catalog.rs`) and `model_type == "qwen3_5"`
- mlx-swift-lm is pinned `exact: "3.31.4"` in the root `Package.swift:20`

## Build / test

- `swift build --product afterray-mlx-vlm-worker`
- `swift test --filter AfterRayMlxVlmWorkerTests` (tests live in `swift/AfterRayMlxVlmWorkerTests`); the real-model regression test needs `AFTERRAY_QWEN35_MODEL_DIR` pointing at a verified snapshot

## Watch out

- The similarly named `swift/AfterRayMlxVlmWorker` directory is the worker **core library**, not recall UI and not this executable.
