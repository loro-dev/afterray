# crates/afterrayd — the daemon

Single-binary tokio daemon: socket/RPC, capture import, model jobs, GOP packing, T2 summaries. The `0600` Unix socket is the security boundary — never add unauthenticated endpoints.

## Key anchors

- `main` — Tokio multi-thread runtime (`2 × cores`, min 8 workers, 512 blocking threads) keeps UI accepts free under load.
- `bind_control_socket` — rejects symlinks/non-sockets, chmod `0600`, uid check; peer-uid re-check after `accept`.
- `handle` — artifact reads + `ChatStream` bypass `dispatch`; every vault/decrypt path still uses `run_store`. Unprivileged peers are authorized via `afterray_protocol::authorize_cli_request` and have query payloads redacted. The app is identified by audit token + signature (Team ID or the AfterRay parent cdhash snapshotted at spawn).

- `dispatch` — one arm per `Request` (protocol version lives in `afterray-protocol`).
- `run_store` — **only** way to call sync `Vault` from async (`spawn_blocking`). UI RPC, capture import, OCR/ASR writes all use it.
- Capture: interval scheduler → `consume_capture_events` → `import_artifact` (screen→moment+OCR, audio→encrypted segment, AX→exclusion + attach) → evidence. Audio rows are the durable ASR backlog. (Embedding submission is switched off — see the tools article.)
- Input events: `CaptureEvent::InputEvents` batches → `run_store` → `insert_input_events`; `prune_input_events` (48h) runs beside `enforce_retention`. Acts derived from them must be frozen into `slot_summaries.acts_json` before expiry (phase 3).
- Screen exclusions delete the stored moment after AX names the URL (`delete_excluded_moment`, retried once). Unparseable AX takes the same path. Audio exclusions are pushed to the shim (`push_audio_exclusions`) — a finished `m4a` cannot be sliced.
- T2: `run_slot_t2` (`T2_MAX_ROUNDS = 8`) + 5-min sweeper gated by `t2_may_run` (AC, ≥30% battery, ≥30s idle, load/core ≤0.7).
- `GopPacker::pack_one` — cold stills → closed AV1 GOP; yields within 2s of the next capture tick.
- Agent surfaces: `agent`/`tools`/`ask`/`chat`/`stream`/`memory` (memory is model-free).
- `tools.rs` — the model's whole read surface: **8 read-only tools** in two groups (find a stretch / read one) plus `get_now`. Times are epoch ms **copied, never computed**; there is **no seed** (the clock is a tool, the question carries `[asked at …]`). `RECALL_SYSTEM_PROMPT` lives in `agent.rs` and may not name a tool. Embeddings are **switched off** read and write; search narrowing happens **in SQL**, before ranking. Full design and the numbers behind each choice: [context/agent-tools.md](../../context/agent-tools.md).

## Build / test

- `make v0-daemon` / `make daemon`. Tests: `cargo test -p afterrayd`. Needs shim (`make capture-shim` or `AFTERRAY_CAPTURE_SHIM`).

## Watch out

- **Never call `Vault` from async** — use `run_store`. More worker threads are a safety margin, not a substitute.
- **Thumbnails before GOP commit**: encode while the JPEG is in hand; after `drop_unpinned_stills` Rust cannot decode AV1. Fallback: thumbnail→still→GOP-frame.
- Secrets: LLM API key in Keychain (`LLM_API_KEY_SECRET`); `settings.json` is `0600` via tmp+rename, never stores the key.
- `FavoriteSet` returns "favorites are disabled". T2 v1 remains for compat reads only. No HTTP endpoint — only the NDJSON socket.
