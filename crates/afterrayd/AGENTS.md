# crates/afterrayd — the daemon

Single-binary tokio daemon (`main.rs`, ~4100 lines — dispatch, capture loop, and T2 machinery all live here). It binds a hardened `0600` Unix socket, spawns the Swift capture shim, imports artifacts into `afterray-store`'s vault, submits OCR/ASR/embedding jobs to `afterray-models`' `ModelQueue`, and runs background GOP packing and T2 slot summaries. The socket is the security boundary: plaintext history leaves the vault only over this uid-checked socket — never add unauthenticated endpoints.

## Key anchors

- `main.rs:57 bind_control_socket` — rejects symlinks/non-sockets, chmod `0600`, uid check; peer-uid re-check per connection at main.rs:251.
- `main.rs:529 handle` — artifact reads (`ReadArtifact`/`ReadGopSegment`/`ReadGopFrame`/`ReadThumbnail`, header line + raw bytes) and `ChatStream` (NDJSON events) bypass `dispatch`.
- `main.rs:625 dispatch` — one match arm per `Request` variant (protocol version lives in `afterray-protocol`, not here).
- `main.rs:614 run_store` — **the** way to call sync `Vault` methods from async (`spawn_blocking` wrapper).
- Capture flow: interval scheduler (default 10s, `AFTERRAY_CAPTURE_INTERVAL_SECONDS`) → `consume_capture_events` (main.rs:1767) → `import_artifact` (main.rs:1830; screen→`insert_moment`+OCR, audio→`insert_audio_segment`+ASR, AX→exclusion check + `attach_accessibility_snapshot`) → `insert_text_evidence`, then `submit_embedding` (main.rs:2075).
- `main.rs:1956` — screen exclusions delete the already-stored moment (`delete_excluded_moment`), because only the AX snapshot carries the URL; keep that ordering. The delete *is* the guarantee, so it is logged and retried once (main.rs:2055). An unparseable AX snapshot takes the same path — an unnamed app cannot be checked.
- `main.rs:1537 push_audio_exclusions` — audio cannot be deleted afterwards (a 5-min `m4a` cannot be sliced), so the bundle list goes to the shim, which drops audio while an excluded app is frontmost.
- `main.rs:1944 run_slot_t2` — T2 pass: `agent.rs:run_agent_loop` over a T1 card with `T2_MAX_ROUNDS = 8` (main.rs:1948), then `parse_t2_card_v2` + `verify_t2_card` grounding, persisted via `put_t2_summary_v2`.
- `main.rs:2238 spawn_slot_summarizer` — 5-min sweeper gated by `t2_may_run` (main.rs:2102: AC power, ≥30% battery, ≥30s idle, load/core ≤0.7 — all fail-closed); yields to in-flight OCR.
- `gop_packer.rs:114 GopPacker::pack_one` — packs cold stills into closed AV1 GOPs: `commit_gop` → verify → `mark_gop_ready` → `drop_unpinned_stills`; yields within 2s of the next capture tick (`should_yield_to_capture`, gop_packer.rs:71).
- Agent surfaces: `agent.rs` (read-only tool loop), `tools.rs:18 ToolHost` (allowlisted read-only history tools), `ask.rs` (single-shot), `chat.rs` + `stream.rs` (persisted multi-turn NDJSON), `memory.rs` (deterministic episode segmentation — deliberately no model spend).

## Build / test

- `make v0-daemon` (scripts/run-v0.sh); `make daemon` for dev. Tests: `cargo test -p afterrayd`.
- Needs the shim binary (`make capture-shim`) or `AFTERRAY_CAPTURE_SHIM` set.

## Watch out

- **Never call `Vault` methods directly from async code** — go through `run_store`; blocking a tokio worker historically froze socket accepts and chat streams.
- **Thumbnails before GOP commit**: `encode_run` builds the thumbnail while the decrypted JPEG is in hand (gop_packer.rs:232); after `drop_unpinned_stills` the JPEG is gone and Rust cannot decode AV1 back. `read_moment_thumbnail` (main.rs:2777) has the thumbnail→still→GOP-frame fallback chain.
- Secrets: LLM API key goes to the Keychain via `afterray_store::store_secret(LLM_API_KEY_SECRET)`; `legacy_llm_api_key` in settings is read-once and `skip_serializing` (main.rs:446). `settings.json` is written `0600` via tmp+rename.
- `FavoriteSet` RPC returns "favorites are disabled" (main.rs:676) even though the store has favorite/pinning machinery.
- `T2_SYSTEM_PROMPT`/`T2Card` v1 remain for compat reads only; new summaries go through `_v2`.
- No HTTP/gRPC/health endpoint — only the NDJSON Unix socket.
