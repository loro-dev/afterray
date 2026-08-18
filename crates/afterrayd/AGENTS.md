# crates/afterrayd — the daemon

Single-binary tokio daemon: socket/RPC, capture import, model jobs, GOP packing, T2 summaries. The `0600` Unix socket is the security boundary — never add unauthenticated endpoints.

## Key anchors

- `main` — Tokio multi-thread runtime (`2 × cores`, min 8 workers, 512 blocking threads) keeps UI accepts free under load.
- `bind_control_socket` — rejects symlinks/non-sockets, chmod `0600`, uid check; peer-uid re-check after `accept`.
- `handle` — artifact reads + `ChatStream` bypass `dispatch`; every vault/decrypt path still uses `run_store`. Unprivileged peers are authorized via `afterray_protocol::authorize_cli_request` and have query payloads redacted. The app is identified by audit token + signature (Team ID or the AfterRay parent cdhash snapshotted at spawn).

- `dispatch` — one arm per `Request` (protocol version lives in `afterray-protocol`).
- `run_store` — **only** way to call sync `Vault` from async (`spawn_blocking`). UI RPC, capture import, OCR/ASR writes all use it.
- Capture: heartbeat scheduler (sleeps from `last_capture_ms`, so any capture re-phases it) → `consume_capture_events` → `import_artifact` (screen→moment+OCR, audio→encrypted segment, AX→exclusion + attach, AX-edge→exclusion + `insert_edge_snapshot`, no moment/OCR/thumbnail) → evidence. Audio rows are the durable ASR backlog. (Embedding submission is switched off — see the tools article.)
- Input events: `CaptureEvent::InputEvents` → `run_store` → `insert_input_events`; `input_event_row` maps every v2 field (`text` to its column, the rest into one `extra_json` object, the target verbatim). Retention is the vault's general one — the sweeper's ungated tick keeps only `prune_signal_gaps` (48h, markers). A `Warning` of `input_tap_stalled`/`input_tap_unavailable` becomes a synthetic `signal_gap` row **in the same stream** — T1 reads missing events as "the user did nothing". `freeze_slot_acts` (sweeper, **before and independently of `t2_may_run`**: acts race a deadline with no model in it, so gating it on AC power would lose acts on unplugged laptops) freezes sealed slots into `slot_summaries.acts_json`. See [acts-join](../../context/acts-join.md).
- `fire_capture_tick` — **the only door to a screenshot**, heartbeat or input batch alike (`capture_paused` / `capture_busy` compare-exchange / `recording_active`); `event_capture_is_due` gates the batch on `max(10s, interval)`. Cadence unchanged, phase follows interaction ([event-capture-v2 §3c](../../context/event-capture-v2.md)).
- `ocr_crop.rs` — crops OCR regions to the frontmost window's AX frame and drops junk fragments **before** `insert_text_evidence`; rebuilds `text` and `layout_json` together or not at all. Every geometric uncertainty **fails open** ([capture-pipeline §5](../../context/capture-pipeline.md)).
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
