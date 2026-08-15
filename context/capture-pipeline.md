# Capture pipeline: screen → vault → search/recall

Verified against code 2026-08-15.

End-to-end map of how a captured frame becomes searchable, summarizable history. Follow the stages in order; each stage lists the owning file and the symbols that matter. Owners: `apps/AfterRayCaptureShim` (capture), `crates/afterray-platform-macos` (shim process), `crates/afterrayd` (scheduling + import + background passes), `crates/afterray-store` (vault + indexes), `crates/afterray-models` / `crates/afterray-infer` + Swift workers (OCR/ASR/embedding/LLM).

## 1. Capture — the Swift shim

- Screen capture is **not** in Rust. `apps/AfterRayCaptureShim` is a standalone SwiftPM package (macOS 15, not a target of the root `Package.swift`) using ScreenCaptureKit; the whole shim is one file, `Sources/AfterRayCaptureShim/main.swift`.
- Pull-based: Rust decides timing. stdin commands `capture_screen` (requires `request_id`) and `stop` (main.swift:962-990); stdout carries JSON-line `Event`s only (`ready`/`artifact`/`warning`/`failed`/`stopped`); logs go to stderr.
- Output dir is `0700`, artifact files `0600`; the shim excludes AfterRay's own windows from capture.
- The shim exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI. Build it with `make capture-shim`.

## 2. Shim process ownership — afterray-platform-macos

- `crates/afterray-platform-macos/src/lib.rs:151 MacOsCaptureBackend` spawns and owns the shim child: writes commands to stdin, reads the `CaptureEvent` stream from stdout, bounded channel (128) for backpressure, single-consumer `next_event` (lib.rs:285).
- `ArtifactKind` (lib.rs:108): `screen | system_audio | microphone | accessibility`.
- `power.rs` — `on_ac_power` / `battery_fraction` / `seconds_since_user_input` / `load_per_core` probes; these feed the daemon's fail-closed gates (T2, GOP packing). They return `None` on failure, never a guess.
- This is the only workspace crate allowed `#![allow(unsafe_code)]`.

## 3. Import — afterrayd

- Capture scheduler: a tokio interval task spawned in `start_capture_runtime` (`crates/afterrayd/src/main.rs:902`; the spawn is at :956), default 10s via `AFTERRAY_CAPTURE_INTERVAL_SECONDS`, calling `capture_screen(request_id)`.
- `main.rs:1553 consume_capture_events` → `main.rs:1616 import_artifact`:
  - screen → `Vault::insert_moment` (store lib.rs:819) + OCR job;
  - audio → `insert_audio_segment` (lib.rs:871) + ASR job;
  - accessibility → exclusion check, `attach_accessibility_snapshot` (lib.rs:909), memory observation.
- Exclusions (bundle id / URL domain) are enforced **after** the screenshot lands, by deleting the stored moment (`main.rs:1741-1756` → `delete_moment_and_artifacts`, store lib.rs:1974) — only the AX snapshot carries the URL. Keep the delete-first ordering.
- Every sync `Vault` call from async code goes through `run_store` (`main.rs:614`, a `spawn_blocking` wrapper). Blocking a tokio worker on SQLite/encryption has historically frozen socket accepts and chat streams.

## 4. Vault — afterray-store

- `crates/afterray-store/src/lib.rs:502 Vault` — SQLCipher database plus per-artifact encrypted files. One writer (`Mutex<Connection>`) + a `ReadPool` of `PRAGMA query_only` readers; use readers for reads (a write on a reader errors loudly — intentional).
- Master key comes from the macOS Keychain (`MacOsKeychainProvider`); blake3 derives the DB key and the artifact wrap key. Non-macOS key providers hard-error.
- Artifact encryption: `lib.rs:3655 encrypt_artifact` — random DEK per artifact, XChaCha20-Poly1305, AAD binds purpose + id + content_type, file magic `ARV1` (legacy `ARV0` migrates in the background). Renaming or retyping an artifact makes it undecryptable.
- Schema: `SCHEMA_VERSION = 18` (lib.rs:84), additive `migrate_schema_N` steps in `migrate` (lib.rs:3020). Key tables: `moments`, `artifacts`, `audio_segments`, `text_evidence`, `evidence_fts` (FTS5), `embeddings` (vector_json + Rust cosine scan), `gop_segments`/`gop_frames`, `slot_summaries`, `text_df`, `memories`, `conversations`.
- Retention: `lib.rs:2699 enforce_retention` — oldest-first eviction of non-favorite moments plus orphaned GOP/audio, batches of 256. **Any moment-deleting path must call `flush_card_cache` (lib.rs:1163)** or a settled slot card resurrects deleted frames; `delete_history` also drops overlapping `slot_summaries` (privacy).

## 5. OCR / ASR / embedding — the model layer

- The daemon submits jobs to the in-memory `ModelQueue` (`crates/afterray-models/src/queue.rs:299`); per-capability concurrency: ocr 1, asr 1, embedding 2, llm 1. Durable job state is *not* persisted — the schema's `jobs` table is unused.
- Adapters are wired per capability in `main.rs:316 local_model_adapters`:
  - OCR → Swift Vision worker `apps/AfterRayNativeModelWorker` (one-shot JSON protocol);
  - ASR + embedding → Rust `afterray-model-worker` (`crates/afterray-infer`: Qwen3-ASR via Candle, nomic GGUF embeddings via llama.cpp; deliberately rejects OCR and LLM);
  - LLM → `LlmRouterAdapter` (MLX-local or remote).
- Worker binaries resolve via `resolve_helper_path` (main.rs:388): env var (`AFTERRAY_MODEL_WORKER`, `AFTERRAY_NATIVE_MODEL_WORKER`, `AFTERRAY_MLX_WORKER`) → bundled next to the exe → dev build path.
- OCR geometry is Apple Vision's bottom-left-origin unit square (`OcrRegion`, afterray-models lib.rs:106-110) — flip Y for screen coordinates.
- Results are written back by a spawned task: `Vault::insert_text_evidence` (store lib.rs:2125, applies the CJK bigram fold) then `submit_embedding` (daemon main.rs:1824).

## 6. Search, summaries, cold storage

- Keyword: `Vault::search` (lib.rs:2310) → FTS5 bm25 through `search_index.rs:110 match_query`. **Index and query must both go through `index_text`/`match_query`** (CJK bigram folding) or CJK substring search silently breaks.
- Semantic: `lib.rs:2379 semantic_search` — cosine ≥ `SEMANTIC_MIN_SIMILARITY = 0.72` (lib.rs:93), same `model_version` only. Agent-side fusion: `fuse_search_results` (RRF k=60, lib.rs:2893). The user-facing `Search` RPC is FTS-only on purpose.
- T1 slot cards: `slot.rs` — `SLOT_DURATION_MS` = 30 min (slot.rs:14), `build_slot_card`; pure and deterministic by design (no model spend).
- T2 LLM summaries: `run_slot_t2` (daemon main.rs:1944) driven by a 5-min sweeper (`spawn_slot_summarizer`, main.rs:2238), gated fail-closed by `t2_may_run` (main.rs:2102: AC power, ≥30% battery, ≥30s idle, load/core ≤0.7) and yielding to in-flight OCR.
- Cold storage: `gop_packer.rs` packs stills past the 2-hour hot window into closed AV1 GOPs (`afterray-codec`, rav1e, encode-only). Thumbnails are built in `encode_run` (gop_packer.rs:224) **before** `drop_unpinned_stills` deletes the JPEG, because nothing in Rust can decode AV1 back. Reads follow the thumbnail → still → GOP-frame fallback chain in `read_moment_thumbnail` (main.rs:2777).

## Watch out

- No AV1 **decode** exists in Rust anywhere; clients decode GOP frames themselves (Swift `RecallYUVDisplay` / VideoToolbox).
- `afterray-core` is only two trait definitions — the real store is `afterray-store::Vault`, the real capture is `MacOsCaptureBackend`.
- Background LLM submitters (T2, backfills, agent loops) must use `JobPriority::Background` and multi-round loops must hold `ModelQueue::hold_llm_lease()` (queue.rs:351), or rounds starve behind rivals.
- Timestamps are epoch-ms `i64` everywhere; "day" is local-calendar; slot alignment is wall-clock 30-minute boundaries.
