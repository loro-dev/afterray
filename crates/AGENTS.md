# crates/ — Rust workspace

Nine crates (`Cargo.toml` workspace, edition 2024, rust 1.85). The daemon `afterrayd` captures via a Swift shim, stores everything in `afterray-store`'s encrypted vault, and drives model jobs; clients talk to it over a versioned NDJSON Unix socket (`afterray-protocol`).

## Shared conventions

- Workspace lints (root `Cargo.toml:44-49`): `unsafe_code = "deny"` — the only exception is `afterray-platform-macos` (`#![allow(unsafe_code)]`, FFI boundary); clippy `all` + `pedantic` = warn.
- Timestamps are epoch-ms `i64` everywhere; "day" means local-calendar day (`slot::local_day_bounds`), slots align to wall-clock 30-min boundaries (`slot::slot_start_for`, slot.rs:247).
- Tests are inline `#[cfg(test)]` modules — no `tests/` dirs, no CI workflows in this repo.
- Secrets live in the macOS Keychain (`MacOsKeychainProvider`, store lib.rs:155), never in files.

## Crate index

- [afterrayd](afterrayd/AGENTS.md) — tokio daemon binary: socket/RPC dispatch, capture scheduling, OCR/ASR plumbing, GOP packer, T2 slot summarizer, agent/ask/chat surfaces.
- [afterray-store](afterray-store/AGENTS.md) — the vault: SQLCipher + per-artifact XChaCha20-Poly1305 files, schema migrations, retention, FTS5/semantic search, T1 slot cards.
- [afterray-platform-macos](afterray-platform-macos/AGENTS.md) — `AfterRayCaptureShim` process lifecycle + JSON-lines protocol; power/idle/locale probes.
- [afterray-codec](afterray-codec/AGENTS.md) — encode-only AV1 (rav1e → IVF), JPEG→I420, thumbnails.
- [afterray-core](afterray-core/AGENTS.md) — trait definitions only (`CaptureBackend`, `Store`); no logic.
- [afterray-protocol](afterray-protocol/AGENTS.md) — wire types + `PROTOCOL_VERSION` (src/lib.rs:8); bump the version here, not in the daemon.
- [afterray-models](afterray-models/AGENTS.md) — in-memory `ModelQueue`, worker orchestration, LLM routing and remote-endpoint guards (`src/remote.rs`); the `jobs` table in the store schema is vestigial.
- [afterray-infer](afterray-infer/AGENTS.md) — in-process ASR/embedding backends + the one-shot `afterray-model-worker` binary; deliberately rejects OCR and LLM.
- [afterray-cli](afterray-cli/AGENTS.md) — read-only CLI over the socket (`make status`); keep `skills/afterray/` in sync with it.

## Build / test / lint

- `make check` → `cargo check --workspace`; `make test` → `cargo test --workspace` + `swift test`
- `cargo clippy --workspace --all-targets -- -D warnings` — lint gate
- `make build` builds the capture shim first; the daemon finds it at `apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim` or via `AFTERRAY_CAPTURE_SHIM`
- Useful env vars: `AFTERRAY_DATA_DIR`, `AFTERRAY_SOCKET`, `AFTERRAY_CAPTURE_INTERVAL_SECONDS`, `AFTERRAY_T2_SWEEP_SECONDS` (0 disables), `AFTERRAY_GOP_ARCHIVE` / `AFTERRAY_GOP_REQUIRE_AC` / `AFTERRAY_GOP_KEYINT`
