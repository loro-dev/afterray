# Wire protocols: daemon ↔ clients, daemon ↔ workers

Verified against code 2026-08-15.

AfterRay has **three separate JSON protocols**: the versioned control socket between `afterrayd` and its clients (CLI, SwiftUI app), the one-shot worker protocol (OCR/ASR/embedding), and the persistent MLX worker protocol (local LLM). Each has its own version constant; bump both sides of whichever you touch.

## 1. Control socket: afterrayd ↔ CLI / SwiftUI app

- Single source of truth: `crates/afterray-protocol`. `Request` enum (src/lib.rs:22, ~50 variants, `#[serde(tag = "type", rename_all = "snake_case")]`); `Response` envelope `{protocol_version, ok, data?, error?}` (lib.rs:275); `PROTOCOL_VERSION = 7` (lib.rs:8).
- Framing: one request = one JSON object + `\n` over a Unix socket. Three response shapes:
  - single JSON line — the default, served by `dispatch` (`crates/afterrayd/src/main.rs:625`);
  - artifact reads (`ReadArtifact` / `ReadGopSegment` / `ReadGopFrame` / `ReadThumbnail`) — a JSON header line (`ArtifactMeta`) followed by exactly `byte_length` raw bytes;
  - `ChatStream` — NDJSON `ChatStreamEvent` lines until `done`/`error`.
  - Binary/streaming requests are intercepted in the daemon's `handle` loop (main.rs:529) *before* `dispatch`; `dispatch` fails them if reached. New binary or streaming requests must follow that split.
- Swift mirror: `swift/AfterRayRecall/Sources/DaemonClient.swift` — `UnixSocketDaemonClient` (line 148, actor), a hand-declared `WireRequest` (line 442) with snake_case CodingKeys, and `protocolVersion = 7` (line 149) enforced on every response (lines 426, 790). **Bump Rust and Swift together — there is no negotiation; a mismatch fails every request with `protocolMismatch`.**
- Evolution rules: additive-only; new optional fields use `#[serde(default, skip_serializing_if = "Option::is_none")]`. Never rename variants/fields — the `*_wire_shape_is_stable` tests in protocol lib.rs pin exact JSON bytes. For enums persisted in settings, follow `LlmProvider`: lenient custom `Deserialize` mapping retired/unknown labels to the default, strict serialization. Mirror every new field in Swift's `WireRequest` and add a wire-shape test (Swift side: `DaemonWireTests` / `ChatWireTests`).
- Socket path resolution lives only in `crates/afterray-protocol/src/socket.rs` (`default_socket_path`, line 22): `AFTERRAY_SOCKET` env → `<checkout>/.afterray-dev/afterray.sock` (only when the executable sits under `target/{debug,release}`) → `~/Library/Application Support/AfterRay/afterray.sock`. Daemon, CLI, and app must all resolve through this — they used to diverge.
- Security: the daemon binds the socket `0600` inside a `0700` directory, rejects symlink/non-socket/foreign-owned paths, and re-checks the peer uid per connection (`bind_control_socket`, afterrayd main.rs:57; peer check main.rs:251). Artifact bytes travel the socket **already decrypted** — the filesystem boundary is the entire access control. `ArtifactPayload` zeroizes its bytes on `Drop` (protocol lib.rs:761).
- `Status.host_build` echoes `AFTERRAY_HOST_BUILD` (protocol lib.rs:318) so the app can detect and restart a stale daemon after an in-place update — a separate concern from `protocol_version`.

## 2. One-shot worker protocol (OCR / ASR / embedding)

- `crates/afterray-models/src/process.rs`: `WORKER_PROTOCOL_VERSION = 1` (line 7). One child process per inference: exactly one JSON request on stdin, exactly one JSON response on stdout, stderr = logs only. 300s timeout, 16 MiB stdout cap (process.rs:57-58). The response must echo the protocol version and its output capability must match the request.
- Speakers: the Rust `afterray-model-worker` (`crates/afterray-infer/src/bin/afterray-model-worker.rs` — ASR + embedding; rejects OCR and LLM) and the Swift `apps/AfterRayNativeModelWorker` (macOS Vision OCR; reports errors as `{error, retryable}` on stdout and still exits 0).
- Retry contract: `retryable: true` maps to retryable `AdapterError::Process`; `false` maps to `MissingModel`. Only `Process`/`Io`/`Timeout` errors retry (`AdapterError::retryable`).

## 3. Persistent MLX worker protocol (local LLM)

- `crates/afterray-models/src/persistent_mlx.rs`: `MLX_WORKER_PROTOCOL_VERSION = 1` (line 17). A long-lived child speaking newline-delimited JSON both ways: requests `load`/`generate`/`cancel`; responses `ready`/`delta`/`final`/`cancelled`/`error`, each echoing `request_id`. Load timeout 180s, generate 300s, restart backoff 1s. `verify_model` (line 274) re-checks the pinned manifest + `.afterray-ready.json` marker before every spawn.
- Swift side: `swift/AfterRayMlxVlmWorker/Sources/WorkerCore.swift` — `MlxWorker` actor (line 267), `mlxWorkerProtocolVersion = 1` (line 8). Single-flight: one `generate` at a time; `cancel` is acknowledged only after the MLX task actually stops. Revision pins `qwen35_4BRevision`/`qwen35_9BRevision` (WorkerCore.swift:10-11) must stay equal to `QWEN35_4B_MLX_REVISION`/`QWEN35_9B_MLX_REVISION` in `crates/afterray-models/src/catalog.rs` (verified equal today).
- Remote LLM alternative: `LlmRouterAdapter` (`crates/afterray-models/src/remote.rs:127`) routes to Ollama/OpenAI-compatible HTTP only through `check_origin` (remote.rs:484 — https, or http only to loopback); reqwest clients are built with redirects disabled so prompts and API keys can't leak to a redirect target.

## Watch out

- **stdout of every worker is protocol-only** — a stray `print` kills the job as invalid output (there is a regression test for this). Logs go to stderr (`WorkerLog` in Swift).
- `$TMPDIR/afterray-v0.sock` is the **retired** socket default. Never fall back to `$TMPDIR` (world-writable, pre-bindable), and never key dev-socket detection off the working directory — only off the executable path. The Swift client's last-resort `$TMPDIR` fallback is dead in practice (the app always passes a path explicitly); don't "fix" Rust to match it.
- Dead-but-present wire surface: `Request::FavoriteSet` (daemon replies "favorites are disabled", main.rs:676), `PackStatus.keep_stills` (always false), `LlmProvider` labels `builtin`/`local` (retired GGUF backends, kept decode-only).
- Fixture JSON in daemon tests shows `"protocol_version": 1` — that is test data, not the real version.
- `afterray download` bypasses the daemon and uses `afterray-models` directly — intentional, not a bug.
