# Capture pipeline: screen → vault → search/recall

Verified against code 2026-08-17.

End-to-end map of how a captured frame becomes searchable, summarizable history. Follow the stages in order; each stage lists the owning file and the symbols that matter. Owners: `apps/AfterRayCaptureShim` (capture), `crates/afterray-platform-macos` (shim process), `crates/afterrayd` (scheduling + import + background passes), `crates/afterray-store` (vault + indexes), `crates/afterray-models` / `crates/afterray-infer` + Swift workers (OCR/ASR/embedding/LLM).

## 1. Capture — the Swift shim

- Screen capture is **not** in Rust. `apps/AfterRayCaptureShim` is a standalone SwiftPM package (macOS 15, not a target of the root `Package.swift`) using ScreenCaptureKit; the whole shim is one file, `Sources/AfterRayCaptureShim/main.swift`.
- Pull-based: Rust decides timing. stdin commands `capture_screen` (requires `request_id`) and `stop` (main.swift:962-990); stdout carries JSON-line `Event`s only (`ready`/`artifact`/`warning`/`failed`/`input_events`/`stopped`); logs go to stderr.
- Output dir is `0700`, artifact files `0600`; the shim excludes AfterRay's own windows from capture.
- Screenshot and Accessibility evidence share one `ForegroundCaptureContext`. AX selects the frontmost app and its focused window (`main window` fallback); the screenshot refreshes `SCShareableContent` and selects the display with the largest intersection with that window's global frame, falling back to `CGMainDisplayID` when AX has no usable frame. PID, window id, and frame are rechecked before and after the screenshot, and a changed context drops the whole tick. The continuous audio stream remains separate and is never duplicated or restarted as focus crosses displays.
- The AX walk stubs the `AXMenuBar` subtree (menus were 80–90% of walked nodes in native apps; no consumer reads them) and is time-boxed: 100ms per AX call process-wide plus a 500ms whole-walk deadline that sets `truncated` like the 20k node cap.
- Every AX snapshot also carries `tree_text` — the tree as numbered indented text, or a diff against the same window's previous one — beside the unchanged `root`/`digest`, and the input tap emits the v2 event vocabulary (`burst` with typed text and the field's value, `drag`, `window_changed`). Both are detailed in [event-capture-v2](event-capture-v2.md); the daemon does not consume the new fields yet.
- The shim exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI. Build it with `make capture-shim`.

## 2. Shim process ownership — afterray-platform-macos

- `crates/afterray-platform-macos/src/lib.rs:151 MacOsCaptureBackend` spawns and owns the shim child: writes commands to stdin, reads the `CaptureEvent` stream from stdout, bounded channel (128) for backpressure, single-consumer `next_event` (lib.rs:285).
- `ArtifactKind` (lib.rs:108): `screen | system_audio | microphone | accessibility | accessibility_edge`.
- `power.rs` — `on_ac_power` / `battery_fraction` / `seconds_since_user_input` / `load_per_core` probes; these feed the daemon's fail-closed gates (T2, GOP packing). They return `None` on failure, never a guess.
- This is the only workspace crate allowed `#![allow(unsafe_code)]`.

## 3. Import — afterrayd

- Capture scheduler: a tokio task spawned in `start_capture_runtime`, default 10s via `AFTERRAY_CAPTURE_INTERVAL_SECONDS`. It sleeps until `last_capture_ms + interval` rather than on a fixed interval, because the heartbeat is the **fallback**: an `input_events` batch may pull a capture forward (`event_capture_is_due`, throttled to `max(10s, interval)` since the last request), and sleeping from the atomic every capture already writes re-phases the heartbeat with no channel between the two tasks. Cadence unchanged, phase follows interaction ([plan §1](../docs/event-capture-v2-plan.md)).
- Both paths go through `fire_capture_tick`, the only door to `capture_screen`: `capture_paused` (`CaptureSetPaused` — the app raises it whenever its overlay is frontmost; the session, shim and audio keep running, unlike `RecordStop`), `capture_busy` claimed by compare-exchange, and `recording_active`. A held tick moves nothing, so the caller decides when to ask again.
- `main.rs:1553 consume_capture_events` → `main.rs:1616 import_artifact`:
  - screen → `Vault::insert_moment` (store lib.rs:819) + OCR job;
  - audio → `insert_audio_segment` (lib.rs:871) + ASR job;
  - accessibility → exclusion check, `attach_accessibility_snapshot` (lib.rs:909), memory observation.
- Screen exclusions (bundle id / URL domain) are enforced **after** the screenshot lands, by deleting the stored moment (`main.rs:1956` → `delete_excluded_moment` → `delete_moment_and_artifacts`, store lib.rs:2064) — only the AX snapshot carries the URL. Keep the delete-after-capture ordering. The delete is logged and retried once; an AX snapshot that will not parse takes the same path, since an unnamed app cannot be checked.
- **Audio exclusions cannot work that way** — a finished five-minute `m4a` cannot be sliced — so the bundle list is pushed to the shim (`push_audio_exclusions`, main.rs:1537 → `MacOsCaptureBackend::set_excluded_bundle_ids`) and the shim holds every sample until a foreground check vouches for the moment it arrived, dropping the rest (`ExcludedAudioGate`, main.swift:901). Audio is therefore never written and later cut — nothing unvouched-for reaches a file.
- Input events (`input_events` batches from the shim's listen-only tap) are persisted via `insert_input_events`; a batch that fails to land becomes a `signal_gap` row rather than silence. Since event-capture v2 a row carries content (`text`, and the field's `value` inside `target_json`) and expires with the vault's general retention, not on a clock — only `signal_gap` markers keep the 48h prune, which runs inside `enforce_retention` and on the sweeper's ungated tick so it does not depend on recording. `delete_history` cascades.
- R3 edge snapshots (`accessibility_edge`) are AX-only and **unpaired**: no moment, no thumbnail, no OCR — `edge_snapshot_identity` fails them closed when they name no app, then `insert_edge_snapshot` stores tree + row. They are keyframe content, so they expire with the frames of their era like the events do ([acts-join](acts-join.md)).
- The pairing is load-bearing: the daemon evaluates exclusions **only** in the accessibility branch, so the shim must never emit a screen artifact without one (`main.swift:1157`).
- Every sync `Vault` call from async code goes through `run_store` (`afterrayd` main, a `spawn_blocking` wrapper). Blocking a tokio worker on SQLite/encryption has historically frozen socket accepts and chat streams. The daemon also oversizes its Tokio worker pool (`2 × cores`, min 8) so UI accepts stay free under load.

## 4. Vault — afterray-store

- `crates/afterray-store/src/lib.rs Vault` — SQLCipher database plus per-artifact encrypted files. One writer (`Mutex<Connection>`) + a `ReadPool` of six `PRAGMA query_only` readers; use readers for reads (a write on a reader errors loudly — intentional). Artifact files use an `RwLock` so concurrent UI decrypts share a read lock while puts/deletes take write.
- Master key comes from the macOS Keychain (`MacOsKeychainProvider`); blake3 derives the DB key and the artifact wrap key. Non-macOS key providers hard-error.
- Artifact encryption: `lib.rs:3655 encrypt_artifact` — random DEK per artifact, XChaCha20-Poly1305, AAD binds purpose + id + content_type, file magic `ARV1` (legacy `ARV0` migrates in the background). Renaming or retyping an artifact makes it undecryptable.
- Schema: `SCHEMA_VERSION = 25`, additive `migrate_schema_N` steps in `migrate`. Key tables: `moments`, `artifacts`, `audio_segments`, `text_evidence`, `evidence_fts` (FTS5), `embeddings` (vector_json + Rust cosine scan), `gop_segments`/`gop_frames`, `slot_summaries`, `summary_slot_geometry`, `input_events`, `edge_snapshots`, `text_df`, `memories`, `conversations`.
- Retention: `enforce_retention` — oldest-first eviction of non-favorite moments plus orphaned GOP/audio, batches of 256, then the input events and R3 trees left behind the oldest surviving frame (`prune_input_events_before` / `prune_edge_snapshots_before`). No frames left means no horizon and no sweep. **Any moment-deleting path must call `flush_card_cache`** or a settled slot card resurrects deleted frames; `delete_history` also drops overlapping `slot_summaries` (privacy).

## 5. OCR / ASR / embedding — the model layer

- The daemon submits jobs to the in-memory `ModelQueue` (`crates/afterray-models/src/queue.rs:299`); per-capability concurrency: ocr 1, asr 1, embedding 2, llm 1. Durable job state is *not* persisted — the schema's `jobs` table is unused.
- Adapters are wired per capability in `main.rs:316 local_model_adapters`:
  - OCR → Swift Vision worker `apps/AfterRayNativeModelWorker` (one-shot JSON protocol);
  - ASR + embedding → Rust `afterray-model-worker` (`crates/afterray-infer`: Qwen3-ASR via Candle, nomic GGUF embeddings via llama.cpp; deliberately rejects OCR and LLM);
  - LLM → `LlmRouterAdapter` (MLX-local or remote).
- Worker binaries resolve via `resolve_helper_path` (main.rs:388): env var (`AFTERRAY_MODEL_WORKER`, `AFTERRAY_NATIVE_MODEL_WORKER`, `AFTERRAY_MLX_WORKER`) → bundled next to the exe → dev build path.
- OCR geometry is Apple Vision's bottom-left-origin unit square (`OcrRegion`, afterray-models lib.rs:106-110) — flip Y for screen coordinates.
- Before the write, `ocr_crop.rs` drops regions whose centre falls outside the frontmost window's AX frame, then drops content-free and boundary-clipped short fragments, rebuilding `text` and `layout_json` together ([plan §7](../docs/event-capture-v2-plan.md)). The map from unit square to points needs the shim's `Ready` display size (`AppState::capture_display`, the daemon's only source) and assumes that display sits at the global origin — so a missing snapshot, window, or size, or a window frame that misses those bounds, keeps every region untouched.
- Results are written back by a spawned task: `Vault::insert_text_evidence` (store lib.rs:2125, applies the CJK bigram fold) then `submit_embedding` (daemon main.rs:1824).

## 6. Search, summaries, cold storage

- Keyword: `Vault::search` (lib.rs:2310) → FTS5 bm25 through `search_index.rs:110 match_query`. **Index and query must both go through `index_text`/`match_query`** (CJK bigram folding) or CJK substring search silently breaks.
- Semantic: `lib.rs:2379 semantic_search` — cosine ≥ `SEMANTIC_MIN_SIMILARITY = 0.72` (lib.rs:93), same `model_version` only. Agent-side fusion: `fuse_search_results` (RRF k=60, lib.rs:2893). The user-facing `Search` RPC is FTS-only on purpose.
- T1 slot cards: `slot.rs` — slot length is a user setting (10/20/30/60 min, default 10). The vault persists the whole history as `SlotSegment`s, so old cards keep the length they were summarised at; `slot_bounds_in` clips a slot at a segment boundary rather than letting it straddle two geometries. Every consumer receives explicit bounds; T1 remains pure and deterministic (no model spend).
- T2 LLM summaries: `run_slot_t2` (daemon main.rs:1944) driven by a 5-min sweeper (`spawn_slot_summarizer`, main.rs:2238), gated fail-closed by `t2_may_run` (main.rs:2102: AC power, ≥30% battery, ≥30s idle, load/core ≤0.7) and yielding to in-flight OCR.
- Cold storage: `gop_packer.rs` packs stills past the 2-hour hot window into closed AV1 GOPs (`afterray-codec`, rav1e, encode-only). Thumbnails are built in `encode_run` (gop_packer.rs:224) **before** `drop_unpinned_stills` deletes the JPEG, because nothing in Rust can decode AV1 back. Reads follow the thumbnail → still → GOP-frame fallback chain in `read_moment_thumbnail` (main.rs:2777).

## Watch out

- No AV1 **decode** exists in Rust anywhere; clients decode GOP frames themselves (Swift `RecallYUVDisplay` / VideoToolbox).
- `afterray-core` is only two trait definitions — the real store is `afterray-store::Vault`, the real capture is `MacOsCaptureBackend`.
- Background LLM submitters (T2, backfills, agent loops) must use `JobPriority::Background` and multi-round loops must hold `ModelQueue::hold_llm_lease()` (queue.rs:351), or rounds starve behind rivals.
- Timestamps are epoch-ms `i64` everywhere; "day" is local-calendar; slots align to wall-clock boundaries of whatever length is in force (every offered length divides an hour).
