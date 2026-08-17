# crates/afterrayd — the daemon

Single-binary tokio daemon: socket/RPC, capture import, model jobs, GOP packing, T2 summaries. The `0600` Unix socket is the security boundary — never add unauthenticated endpoints.

## Key anchors

- `main` — Tokio multi-thread runtime (`2 × cores`, min 8 workers, 512 blocking threads) keeps UI accepts free under load.
- `bind_control_socket` — rejects symlinks/non-sockets, chmod `0600`, uid check; peer-uid re-check after `accept`.
- `handle` — artifact reads + `ChatStream` bypass `dispatch`; every vault/decrypt path still uses `run_store`. Unprivileged peers are authorized via `afterray_protocol::authorize_cli_request` and have query payloads redacted. The app is identified by audit token + signature (Team ID or the AfterRay parent cdhash snapshotted at spawn).
- `dispatch` — one arm per `Request` (protocol version lives in `afterray-protocol`).
- `run_store` — **only** way to call sync `Vault` from async (`spawn_blocking`). UI RPC, capture import, OCR/ASR writes all use it.
- Capture: interval scheduler → `consume_capture_events` → `import_artifact` (screen→moment+OCR, audio→encrypted segment, AX→exclusion + attach) → evidence. Audio rows are the durable ASR backlog. (Embedding submission is switched off — see the tools article.)
- Screen exclusions delete the stored moment after AX names the URL (`delete_excluded_moment`, retried once). Unparseable AX takes the same path. Audio exclusions are pushed to the shim (`push_audio_exclusions`) — a finished `m4a` cannot be sliced.
- `compute.rs ComputeGovernor` — the gate for background OCR, ASR, summary, and archive work; `compute_status` reports it. Full map: [context/compute-governance.md](../../context/compute-governance.md).
- T2: `run_slot_t2` (`T2_MAX_ROUNDS = 8`) + 5-min sweeper through `run_slot_t2_recording`; queue-inclusive durations feed the dashboard estimate. `ComputeRunNow` forces one workload for up to 30 minutes and wakes its sweeper.
- `GopPacker::pack_one` — cold stills → closed AV1 GOP; yields within 2s of the next capture tick.
- Agent surfaces: `agent`/`tools`/`ask`/`chat`/`stream`/`memory` (memory is model-free).
- `tools.rs` — the model's whole read surface: **8 read-only tools** in two groups (find a stretch / read one) plus `get_now`. Times are epoch ms **copied, never computed**; there is **no seed** (the clock is a tool, the question carries `[asked at …]`). `RECALL_SYSTEM_PROMPT` lives in `agent.rs` and may not name a tool. Embeddings are **switched off** read and write; search narrowing happens **in SQL**, before ranking. Full design and the numbers behind each choice: [context/agent-tools.md](../../context/agent-tools.md).

## Build / test

- `make v0-daemon` / `make daemon`. Tests: `cargo test -p afterrayd`. Needs shim (`make capture-shim` or `AFTERRAY_CAPTURE_SHIM`).

## Watch out

- **Screen text is not pausable** — there is no OCR backlog, so a skipped frame is never indexed by anything later; only `ComputeMode::Off` stops it. Suspending **drains, never kills**, and interactive work never consults the governor. Reasons for all three: [context/compute-governance.md](../../context/compute-governance.md).
- `gop_packer::pack_one` holds **no power policy of its own** — the governor is the only gate. The old `require_ac` "backstop" made a forced Archive run on battery return `Ok(None)`, which the caller read as an empty backlog and cancelled its own override with.
- **Never call `Vault` methods directly from async code** — go through `run_store`; blocking a tokio worker historically froze socket accepts and chat streams.
- **Thumbnails before GOP commit**: `encode_run` builds the thumbnail while the decrypted JPEG is in hand (gop_packer.rs:232); after `drop_unpinned_stills` the JPEG is gone and Rust cannot decode AV1 back. `read_moment_thumbnail` (main.rs:3770) tries thumbnail→still→GOP-frame. A cache hit returns the stored 360px JPEG and **ignores `max_edge`** — chat cards must not treat this as a high-res preview.
- Secrets: LLM API key goes to the Keychain via `afterray_store::store_secret(LLM_API_KEY_SECRET)`; `legacy_llm_api_key` in settings is read-once and `skip_serializing` (main.rs:446). `settings.json` is written `0600` via tmp+rename.
- `FavoriteSet` RPC returns "favorites are disabled" (main.rs:676) even though the store has favorite/pinning machinery.
- `T2_SYSTEM_PROMPT`/`T2Card` v1 remain for compat reads only; new summaries go through `_v2`.
- No HTTP/gRPC/health endpoint — only the NDJSON Unix socket.
