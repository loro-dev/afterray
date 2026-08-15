# swift/ — Swift libraries

SwiftPM library targets shared across the AfterRay apps, declared in the root `Package.swift` (macOS 14+, swift-tools 5.10). `AfterRayRecall` is the dependency-free SwiftUI recall library; `AfterRayMockData` feeds it fixture data; `AfterRayMlxVlmWorkerCore` is the testable core of the MLX VLM inference worker whose executable lives at `apps/AfterRayMlxVlmWorker`. The shipped app (`apps/AfterRay`), Visual Lab, and snapshot tool all build on these.

## Invariants

- **The UI never opens the database or reads encryption keys** (`docs/development.md:112-113`). All data flows from `afterrayd` over a versioned Unix socket; if a feature seems to need direct vault access, it belongs behind a new daemon request instead.
- `swift/AfterRayMlxVlmWorkerTests` (test target for the worker core) lives here too, but it is inference infrastructure, not recall UI.

## Build / test

- `swift test` (repo root) — runs `AfterRayRecallTests` and `AfterRayMlxVlmWorkerTests`; `make test` additionally runs `cargo test --workspace`.
- `make visual-lab` / `make settings-lab` / `make chat-lab` — mock-data UI loops; `make snapshots` — offscreen PNGs to `/tmp/afterray-snapshots`.
- No Swift linter or formatter is configured; the clippy gate (`cargo clippy --workspace --all-targets -- -D warnings`) is Rust-only.

## Index

- [AfterRayRecall](AfterRayRecall/AGENTS.md) — recall UI, Unix-socket daemon client, wire models, settings/chat chrome
- [AfterRayMockData](AfterRayMockData/AGENTS.md) — fixture implementations of the recall protocols for previews, labs, and snapshots
- [AfterRayMlxVlmWorker](AfterRayMlxVlmWorker/AGENTS.md) — Qwen3.5 MLX inference worker core and its line-delimited JSON protocol
