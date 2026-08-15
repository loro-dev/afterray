# crates/afterray-store — the vault

The encrypted vault (`lib.rs`, ~6400 lines): a SQLCipher database plus per-artifact XChaCha20-Poly1305 files, with schema migrations, retention, FTS5 + semantic search, T1 slot cards, and GOP segment bookkeeping. `Vault` is synchronous — async callers (the daemon) must reach it through `afterrayd`'s `run_store`.

## Key anchors

- `lib.rs:502 Vault` — single-writer `Mutex<Connection>` + `ReadPool` (3 `PRAGMA query_only` readers, lib.rs:522) + `card_cache` + `artifact_io` mutex.
- `lib.rs:562 Vault::open` — master key from `MacOsKeychainProvider` (lib.rs:155, Keychain service `dev.afterray.v0.vault`); blake3-derives the DB key and artifact wrap key (`DATABASE_KEY_CONTEXT`/`ARTIFACT_WRAP_KEY_CONTEXT`, lib.rs:113-114); runs `migrate`, reconcile, then `enforce_retention`. Non-macOS key providers hard-error.
- Encryption: `lib.rs:3655 encrypt_artifact` — random DEK per artifact, XChaCha20-Poly1305, AAD binds purpose+id+content_type, file magic `ARV1`; wrapped DEK in the `artifacts` table. Legacy `ARV0` files migrate in background (`run_artifact_maintenance`, lib.rs:2635, spawned by the daemon).
- Schema: `SCHEMA_VERSION = 18` (lib.rs:84), `migrate` (lib.rs:3020) chains additive `migrate_schema_N` steps; `schema_meta` stamps the version. Tables: `sessions`, `artifacts`, `moments`, `audio_segments`, `text_evidence`, `evidence_fts` (FTS5), `embeddings`, `idle_spans`, `gop_segments`/`gop_frames`/`gop_pack_jobs`, `memories`, `conversations`, `slot_summaries`, `text_df`/`text_df_meta`. The `jobs` table is vestigial — model-job state lives in `afterray-models`' in-memory `ModelQueue`.
- Retention: `lib.rs:2699 enforce_retention` — oldest-first eviction of non-favorite moments + orphaned GOP/audio, batches of 256.
- Search: `lib.rs:2310 search` (FTS5 bm25 via `match_query`), `lib.rs:2379 semantic_search` (cosine ≥ `SEMANTIC_MIN_SIMILARITY = 0.72`, lib.rs:93, same `model_version` only), `lib.rs:2893 fuse_search_results` (RRF k=60, agent-only).
- `search_index.rs:52 index_text` / `:110 match_query` — CJK bigram folding for FTS5.
- `slot.rs` — T1 cards: `SLOT_DURATION_MS` 30 min (:14), `build_slot_card` (:893), `SLOT_SUMMARY_SCHEMA_VERSION = 2` (:282), `parse_t2_card_v2`/`verify_t2_card`, `SlotSummaryState` (`Ready`/`SkippedIdle`/`NoData`/`Degraded`). Pure and deterministic — keep it model-free and unit-testable.
- `gop.rs` — `PackPolicy` (hot window 2h, keyint 30; defaults gop.rs:22-25), `fold_pack_runs` (:111), `commit_gop` (:284, can fail `StoreError::GopStale` when retention races), `rollback_orphan_gops`, `drop_unpinned_stills` (:546).
- `infoscore.rs` (IDF scoring against `text_df`), `activity.rs` (AX parsing/activity spans), `memory.rs` (AX digests), `pipeline_bench.rs` (`#[ignore]`d manual bench).

## Build / test

- `cargo test -p afterray-store`; manual bench: `cargo test -p afterray-store -- --ignored --nocapture`.

## Watch out

- **Writer/reader split**: writes take `Vault.connection` (the Mutex); reads should use `readers.get()`. A write on a reader errors loudly — intentional.
- **Any moment-deleting path must call `flush_card_cache`** (lib.rs:1163) or a settled slot card resurrects deleted frames. `delete_history` (lib.rs:2059) must also drop overlapping `slot_summaries` (privacy).
- **FTS is not raw text**: write via `insert_text_evidence` (lib.rs:2125, applies `index_text`), query via `Vault::search` (applies `match_query`). Hand-written `evidence_fts` inserts/queries silently break CJK.
- **Encryption AAD binds artifact id + content_type + purpose** — renaming/retyping an artifact makes it undecryptable. `ARV0` legacy path must stay until `run_artifact_maintenance` completes.
- **Semantic search needs the floor**: `SEMANTIC_MIN_SIMILARITY` + matching `model_version` are part of the contract; nearest-neighbor without a floor is noise.
- Secrets: `store_secret`/`load_secret` use Keychain service `dev.afterray.v0.secrets` (e.g. `LLM_API_KEY_SECRET`, lib.rs:355); non-macOS hard-errors.
