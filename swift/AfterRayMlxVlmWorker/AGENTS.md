# AfterRayMlxVlmWorker — MLX VLM worker core

Testable core (target `AfterRayMlxVlmWorkerCore`) of the Qwen3.5 MLX vision-language inference worker. The executable at `apps/AfterRayMlxVlmWorker` is only a stdin loop (`Sources/main.swift`); all logic lives here so `swift/AfterRayMlxVlmWorkerTests` can import it. The worker process is spawned and supervised by the Rust daemon's model queue (`crates/afterray-models`), never by the UI.

## Key files

- `Sources/WorkerCore.swift:9-12` — `mlxWorkerProtocolVersion = 1`, `mlxRuntimeVersion` ("mlx-swift-lm@3.31.4"), and pinned snapshot revisions `qwen35_4BRevision` / `qwen35_9BRevision`.
- `Sources/WorkerCore.swift` — line-delimited JSON protocol: `load`/`generate`/`cancel` in, `ready`/`delta`/`final`/`cancelled`/`error` out; every response echoes `request_id`.
- `ProtocolWriter` (:68) owns stdout; `WorkerLog` (:87) logs to stderr.
- `installMlxErrorHandler` (:121) — process-wide MLX error sink; mlx-c's default handler would print `MLX error: ...` to **stdout** and exit(-1), corrupting the protocol. Errors inside mlx-swift `withError` scopes still surface as Swift throws.
- `validateLocalSnapshot` (:393) — requires the `.afterray-ready.json` marker with a pinned revision and `model_type == "qwen3_5"` (:431).
- `normalizeModelOutput` (:436) — strips `<think>`/control tokens from model output.

## Invariants

- stdout is protocol-only; log via `WorkerLog` (stderr). Anything else on stdout corrupts the stream.
- Protocol changes must stay in sync with `crates/afterray-models/src/persistent_mlx.rs`.
- Single-flight: one generate at a time. Never ack `cancel` until the MLX task has actually stopped (`WorkerCore.swift:188-191`) — that race was the shape of the Qwen3.5 KV-cache regression.
- KV-cache session reuse only when system instructions are unchanged and `use_kv_cache` is true; generation runs at temperature 0 (:218) with `enable_thinking: false` (:233).
- The snapshot revision constants must match `QWEN35_4B_MLX_REVISION` / `QWEN35_9B_MLX_REVISION` in `crates/afterray-models/src/catalog.rs:7,11`.
- mlx-swift-lm is pinned `exact: "3.31.4"` in the root `Package.swift`; update `mlxRuntimeVersion` together with it.

## Build / test

- `swift test --filter AfterRayMlxVlmWorkerTests` (repo root). The real-model regression test is disabled unless `AFTERRAY_QWEN35_MODEL_DIR` points at a verified snapshot.
- `swift build --product afterray-mlx-vlm-worker`, then `scripts/build-mlx-metallib.sh` — command-line SwiftPM cannot compile Metal shaders, so without a colocated `mlx.metallib` the worker's first MLX call dies with "Failed to load the default metallib". `run-v0.sh` / `build-release.sh` run the script themselves and ship the metallib next to the worker in the app bundle.

## Watch out

- Despite living under `swift/`, this is inference infrastructure, not recall UI — the UI never talks to it directly; requests flow through `afterrayd`.
