# AGENTS.md — afterray-cli

The `afterray` binary: a thin clap front-end that maps subcommands 1:1 onto `afterray_protocol::Request` variants, sends them as newline-delimited JSON over the daemon's Unix socket, and prints `Response.data` as JSON. No capture, storage, or model logic lives here.

## Layout

- `src/main.rs:23 Command` — the clap command tree; `request_from_command` (`main.rs:291`) maps commands to `Request`s; `send()` (`main.rs:619`) is the one-shot JSON-line RPC.
- `save_frame()` (`main.rs:518`) implements the framed artifact read client-side: JSON header line, then exactly `byte_length` raw bytes.
- `src/chat.rs` — `ChatCommand` (`chat.rs:10`); `run_once` (`chat.rs:44`) one-shot chat RPC; `run_stream` (`chat.rs:81`) NDJSON loop that bails if the stream ends without a `done` event.
- Socket path comes from `afterray_protocol::socket::default_socket_path()`; overridable via `--socket` / `AFTERRAY_SOCKET` (`main.rs:14`).

## Watch out

- `afterray download` does NOT talk to the daemon — `run_local_download` (`main.rs:597`) drives `afterray-models` directly. Intentional, not a bug.
- `afterray daemon start` spawns `afterrayd` from `PATH` with `AFTERRAY_SOCKET` set (`main.rs:299`).
- Some commands (`frame`, `slot prompt --user-only`) do their own multi-request dances and return early — don't assume one command = one request.
- Adding a request: change `afterray-protocol` first (plus a `*_wire_shape_is_stable` test), then map it here, then mirror it in Swift's `WireRequest`.
- Keep `skills/afterray/` (the shipped Agent Skill for this CLI's read-only surface) in sync when the command surface changes — root `AGENTS.md` requires it.

## Build / test

- `cargo build -p afterray-cli`; unit tests live in `chat.rs` (`cargo test -p afterray-cli`).
- Smoke test a live daemon: `make status` (= `cargo run -p afterray-cli -- --json status`).
- Lint gate: `cargo clippy --workspace --all-targets -- -D warnings`.
