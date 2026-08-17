# crates/afterray-store — the vault

The encrypted vault (`lib.rs`, ~6400 lines): a SQLCipher database plus per-artifact XChaCha20-Poly1305 files, with schema migrations, retention, FTS5 + semantic search, T1 slot cards, and GOP segment bookkeeping. `Vault` is synchronous — async callers (the daemon) must reach it through `afterrayd`'s `run_store`.

## Key anchors

- `Vault` — single writer + `ReadPool` (6 `query_only` readers) + `card_cache` + `artifact_io` `RwLock` (shared reads, exclusive put/delete/migrate).
- `lib.rs:562 Vault::open` — master key from `MacOsKeychainProvider` (lib.rs:155, Keychain service `dev.afterray.v0.vault`); blake3-derives the DB key and artifact wrap key (`DATABASE_KEY_CONTEXT`/`ARTIFACT_WRAP_KEY_CONTEXT`, lib.rs:113-114); runs `migrate`, reconcile, then `enforce_retention`. Non-macOS key providers hard-error.
- Encryption: `lib.rs:3655 encrypt_artifact` — random DEK per artifact, XChaCha20-Poly1305, AAD binds purpose+id+content_type, file magic `ARV1`; wrapped DEK in the `artifacts` table. Legacy `ARV0` files migrate in background (`run_artifact_maintenance`, lib.rs:2635, spawned by the daemon).
- Schema: `SCHEMA_VERSION = 21`; `migrate` chains additive steps and `schema_meta` stamps the version. `vault_meta.summary_slot_cutover_ms` freezes the 30→10-minute boundary for upgraded vaults. `audio_segments.transcription_*` is the durable ASR queue: old rows with transcript evidence migrate to `done`, and rows without evidence remain recoverable. Tables also include capture/search data, `slot_summaries`, `text_df`/`text_df_meta`, conversations and the vestigial `jobs` table.
- Persisted summary schema 1 is the legacy `title + bullets` card and must remain readable/exportable; schema 2 owns description/threads/entities/decisions/not-captured. Never infer one shape from nullable columns alone.
- Retention: `lib.rs:2699 enforce_retention` — oldest-first eviction of non-favorite moments + orphaned GOP/audio, batches of 256.
- Search: `search_filtered` — FTS5 bm25 via `match_query`; `SearchFilter` narrows time + app **in SQL, before ranking** (filtering afterwards makes older evidence unreachable). `search` is the unfiltered wrapper. `semantic_search`/`fuse_search_results` have no callers: no vector index.
- `search_index.rs:52 index_text` / `:110 match_query` — CJK bigram folding for FTS5.
- `find_slot_mentions` / `match_slot_mention` — index over stored v2 summaries (entities, threads, titles); same `SearchFilter`. Candidates are matched and ranked **against JSON values via `json_each`**, never the serialised card: raw `LIKE` also hit serde's key names (`"text"`, `"name"`, `"prose"`), filling the window with rows the exact matcher then dropped. A raw `LIKE` on the longest whitespace-free token stays as a cheap superset gate — a tighter one drops rows silently, since the decision happens in `fold_for_match`'s whitespace-free space. `slot_title_covering` uses the row's own `slot_end_ms`; never recompute 30-vs-10-minute bounds.
- `slot.rs` — T1 cards: legacy 30-minute and current 10-minute explicit `SlotBounds`, `build_slot_card_with_end`, v2 parsing/grounding, and `SlotSummaryState`. Pure and deterministic — keep it model-free and unit-testable.
- `gop.rs` — `PackPolicy` (hot window 2h, keyint 30; defaults gop.rs:22-25), `fold_pack_runs` (:111), `commit_gop` (:284, can fail `StoreError::GopStale` when retention races), `rollback_orphan_gops`, `drop_unpinned_stills` (:546).
- `infoscore.rs` (IDF scoring against `text_df`), `activity.rs` (AX parsing/activity spans), `memory.rs` (AX digests), `pipeline_bench.rs` (`#[ignore]`d manual bench).

- `compute_backlog(now, policy)` counts the durable background pile for the dashboard, reusing `gop::PACK_CANDIDATE_PREDICATE` and `AUDIO_CLAIMABLE_PREDICATE` — **share those consts, never hand-copy a selection rule**: both copies drifted (missing loginwindow exclusions, missing retry backoff) and the "start now" count could not reach zero. Only *drainable* work counts: packed moments are excluded (their JPEG is gone) and `unindexed_moments` looks back one day. Cache the result; these are range scans with per-row probes.
- `recent_summary_runs(limit)` reads the `latency_ms` already persisted on `slot_summaries` so the compute dashboard can say how long summaries usually take. There is no index on `produced_at_ms`: the daemon reads it **once at startup**, never on a polling path.

## Build / test

- `cargo test -p afterray-store`; manual bench: `cargo test -p afterray-store -- --ignored --nocapture`.

## Watch out

- **Writer/reader split**: writes take `Vault.connection` (the Mutex); reads should use `readers.get()`. A write on a reader errors loudly — intentional.
- **Any moment-deleting path must call `flush_card_cache`** (lib.rs:1163) or a settled slot card resurrects deleted frames. `delete_history` (lib.rs:2059) must also drop overlapping `slot_summaries` (privacy).
- **FTS is not raw text**: write via `insert_text_evidence` (lib.rs:2125, applies `index_text`), query via `Vault::search` (applies `match_query`). Hand-written `evidence_fts` inserts/queries silently break CJK.
- **Encryption AAD binds artifact id + content_type + purpose** — renaming/retyping an artifact makes it undecryptable. `ARV0` legacy path must stay until `run_artifact_maintenance` completes.
- **Semantic search has no callers**: full scan, no vector index, disabled pending redesign ([agent-tools](../../context/agent-tools.md)). If it returns, `SEMANTIC_MIN_SIMILARITY` + matching `model_version` remain contract.
- Secrets: `store_secret`/`load_secret` use Keychain service `dev.afterray.v0.secrets` (e.g. `LLM_API_KEY_SECRET`, lib.rs:355); non-macOS hard-errors.
