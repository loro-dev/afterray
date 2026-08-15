# AGENTS.md — apps/

`apps/` holds the macOS executables: the shipped app, the capture shim, two model workers, and the mock-data visual tooling. The shared SwiftUI code and daemon client live in `swift/` (`swift/AfterRayRecall`, `swift/AfterRayMockData`); these apps are thin shells over them. Build/test entry point is the root `Makefile`.

## Index

Targets of the **root** `Package.swift` (built with plain `swift build`):

- [AfterRay/](AfterRay/AGENTS.md) — shipped app (`afterray-app` product): menu bar, overlay panel, daemon supervision, onboarding, Sparkle updates
- [AfterRayNativeModelWorker/](AfterRayNativeModelWorker/AGENTS.md) — one-shot Vision OCR worker (`afterray-native-model-worker`)
- [AfterRayMlxVlmWorker/](AfterRayMlxVlmWorker/AGENTS.md) — persistent MLX VLM worker executable (`afterray-mlx-vlm-worker`); all logic is in the `AfterRayMlxVlmWorkerCore` target under `swift/`
- [AfterRayVisualLab/](AfterRayVisualLab/AGENTS.md) — interactive mock-data UI harness (`afterray-visual-lab`)
- [AfterRayVisualSnapshots/](AfterRayVisualSnapshots/AGENTS.md) — offscreen PNG snapshot tool (`afterray-visual-snapshots`)

Standalone SwiftPM package, **not** part of the root package (own `Package.swift`, own `.build/`):

- [AfterRayCaptureShim/](AfterRayCaptureShim/AGENTS.md) — ScreenCaptureKit boundary for the Rust daemon; build with `make capture-shim`

## Watch out

- Building the root package does **not** build the capture shim; its binary is `apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim`.
- SwiftPM emits bare executables; the `.app` bundle (Info.plist, Sparkle.framework, helpers) is assembled by `scripts/build-release.sh` / `scripts/run-v0.sh`.
- No Swift linter is configured; the lint gate is Rust-only (`cargo clippy --workspace --all-targets -- -D warnings`).
