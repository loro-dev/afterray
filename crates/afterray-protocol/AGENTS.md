# AGENTS.md — afterray-protocol

Single source of truth for the wire contract between `afterrayd` and its clients (the `afterray` CLI and the SwiftUI app). Defines the `Request`/`Response` JSON envelope, every shared payload struct, `PROTOCOL_VERSION`, and the socket-path resolution rules. No server, chat, or model logic lives here — those are in `afterrayd` and `afterray-models`.

## Wire contract

- `Request` enum (`src/lib.rs:22`): `#[serde(tag = "type", rename_all = "snake_case")]`, ~50 variants (`ping`, `status`, `timeline_since`, `search`, `chat_stream`, `shutdown`, …).
- `Response` envelope (`src/lib.rs:275`): `{protocol_version, ok, data?, error?}`; `Response::success`/`failure` always stamp `PROTOCOL_VERSION` (`src/lib.rs:8`).
- Three framings: single JSON line (default); artifact reads = JSON header line + exactly `byte_length` raw bytes (`ArtifactMeta`/`ArtifactPayload`, `src/lib.rs:742`); `ChatStreamEvent` (`src/lib.rs:826`) = NDJSON lines tagged `kind` until `done`/`error`. New binary/streaming requests must be intercepted in afterrayd's `handle` loop before `dispatch`, like the existing ones — `dispatch` rejects them.
- `PROTOCOL_VERSION` (`src/lib.rs:8`, currently 13) and `UnixSocketDaemonClient.protocolVersion` (`swift/AfterRayRecall/Sources/DaemonClient.swift`) must bump together — the Swift client hard-rejects any mismatch; there is no negotiation.
- CLI vs app: `cli_access.rs` classifies each `Request` as Query / Evidence / Privileged. Unprivileged socket peers (`afterray` CLI, agents) get Query always, Evidence only while `cli_evidence_until_ms` is in the future, and never Privileged. The AfterRay app is recognized by socket audit token + code signature (`afterray-platform-macos::peer_is_afterray_app`), never by path.
- Evolve additively only: new optional fields with `#[serde(default, skip_serializing_if = "Option::is_none")]`. Never rename variants/fields — the `*_wire_shape_is_stable` tests (`src/lib.rs:890+`) pin exact JSON bytes and will fail. Add a wire-shape test for every new/changed request, and mirror new request fields in Swift's `WireRequest` (manual snake_case CodingKeys in `DaemonClient.swift`).
- Enums persisted in settings follow `LlmProvider` (`src/lib.rs:323`): lenient custom `Deserialize` degrading unknown/retired labels (`builtin`, `local`) to the default; strict serialization.
- Shared helpers both daemon and clients rely on: `local_calendar_day_bounds_ms` (`src/lib.rs:864`), `summary_language_options()` (`src/lib.rs:436`).

## Socket paths (`src/socket.rs`)

- This module is the only resolver — daemon, CLI, and app must all use it (they diverged once; see the module doc). `default_socket_path()` (`socket.rs:22`): `AFTERRAY_SOCKET` env → `<checkout>/.afterray-dev/afterray.sock` (only when the exe sits under `target/{debug,release}`) → `~/Library/Application Support/AfterRay/afterray.sock` (`installed_socket_path`, `socket.rs:43`).
- Never fall back to `$TMPDIR` (world-writable, pre-bindable) and never key dev detection off the CWD — the exe-path check exists because a working directory is attacker-chosen.
- Artifact bytes cross the socket already decrypted; filesystem permissions on the socket are the entire trust boundary. `ArtifactPayload` zeroizes its bytes on `Drop` (`src/lib.rs:761`).

## Build / test

- `cargo test -p afterray-protocol` — pure unit tests, no daemon needed.
- Live smoke test: `make status` (`cargo run -p afterray-cli -- --json status` against a running daemon).

## Watch out

- Dead-but-present surface: `Request::FavoriteSet` (daemon replies "favorites are disabled"), `PackStatus.keep_stills` (always false), `LlmProvider` labels `builtin`/`local` (retired GGUF backend, decode-only).
- Fixture JSON in afterrayd tests showing `"protocol_version": 1` is not the real version.
- The Swift client still lists the retired `$TMPDIR` path as a last-resort fallback; don't "fix" the Rust side to match — the Rust behavior is the hardened one.
