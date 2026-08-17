# AGENTS.md — afterray-cli

The `afterray` binary: a thin clap front-end that maps **query and evidence** subcommands onto `afterray_protocol::Request` variants, sends them as newline-delimited JSON over the daemon's Unix socket, and prints `Response.data` as JSON. Writes, ask, and chat are not on this CLI — they live in the app. No capture, storage, or model logic lives here. Agent documentation is `afterray docs` (`src/docs.rs`); keep `skills/afterray/` pointing at it.

## Layout

- `src/main.rs` `Command` — the clap command tree; `request_from_command` maps commands to `Request`s; `send()` is the one-shot JSON-line RPC.
- `save_frame()` implements the framed artifact read client-side: JSON header line, then exactly `byte_length` raw bytes. Evidence-gated by the daemon.
- `src/docs.rs` — `afterray docs` / `docs --json`; this is what the Skill should tell agents to read.
- Socket path comes from `afterray_protocol::socket::default_socket_path()`; overridable via `--socket` / `AFTERRAY_SOCKET`.

## Watch out

- `afterray download` does NOT talk to the daemon — `run_local_download` (`main.rs:597`) drives `afterray-models` directly. Intentional, not a bug.
- Some commands (`frame`) do their own multi-request dances and return early — don't assume one command = one request.
- Adding a request: change `afterray-protocol` first (plus a `*_wire_shape_is_stable` test), then map it here, then mirror it in Swift's `WireRequest`.
- Keep `skills/afterray/` (the shipped Agent Skill for this CLI's read-only surface) in sync when the command surface changes — root `AGENTS.md` requires it.

## Build / test

- `cargo build -p afterray-cli`; unit tests live in `docs.rs` (`cargo test -p afterray-cli`).
- Smoke test a live daemon: `make status` (= `cargo run -p afterray-cli -- --json status`).
- Lint gate: `cargo clippy --workspace --all-targets -- -D warnings`.
