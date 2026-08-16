# AfterRayRecall — recall UI library

Dependency-free (system frameworks only) SwiftUI library holding everything cross-app: the recall surface, the Unix-socket daemon client, wire models, and settings/chat chrome. Consumed by the shipped app (`apps/AfterRay`), the Visual Lab, and the snapshot tool; tests and previews drive it through `AfterRayMockData`, so views take loader closures and protocol models rather than a live daemon.

## Key files

- `Sources/DaemonClient.swift:148` `UnixSocketDaemonClient` (actor) — JSON-line requests over a Unix socket; `protocolVersion = 8` (:149), checked on every response. Protocols `RecallDaemonServing` (:22), `AfterRayChatServing` (:67), `AfterRayDaemonServing` (:99) are the injection seam; `WireRequest` (:442) is the snake_case wire shape.
- `Sources/RecallStore.swift:4` `RecallStore` — `@MainActor` timeline/playhead state; `Sources/RecallStore.swift:302` `RecallImageRepository` (actor) — NSCache + in-flight dedup of artifact bytes.
- `Sources/RecallModels.swift` — `RecallSession` (:3), `RecallMoment` (:21), `RecallGopRef` (:133), `ArtifactPayload` (:163); all `Codable` with explicit snake_case `CodingKeys`.
- `Sources/RecallView.swift:9` `RecallView` — the main recall surface (2396 lines; `RecallPalette` at :2205).
- `Sources/AfterRayControlModel.swift:4` — recording/search state; `Sources/AfterRayChatModel.swift:46` chat model behind `AfterRayChatModeling` (:4).
- `Sources/AfterRaySettingsChrome.swift:5` `AfterRaySettingsModeling` + `AfterRaySettingsView` (:276) — settings UI generic over the protocol, so mock and real models share it.
- `Sources/HangWatchdog.swift:36` `HangJudge` + `OverlayVisibility` (:6) — terminates the process if the main thread stalls ~12s while the overlay is visible.
- `Tests/` (XCTest, `@testable import AfterRayRecall`) — `DaemonWireTests.swift` and `ChatWireTests.swift` pin the wire shape against the Rust daemon.

## Invariants

- The UI never opens the database or reads encryption keys (`docs/development.md:112-113`) — everything arrives via `UnixSocketDaemonClient`.
- `protocolVersion` must stay in lockstep with `PROTOCOL_VERSION: u32 = 8` (`crates/afterray-protocol/src/lib.rs:8`); bump both on any wire change or every request fails with `protocolMismatch`.
- Concurrency: stores are `@MainActor` `ObservableObject`s; the socket client and image repository are actors; daemon I/O runs in `Task.detached(priority: .userInitiated)` (`DaemonClient.swift:394,416`). Never block the main thread — the HangWatchdog kills the app.
- Unary socket reads have a 30s receive deadline (`DaemonClient.swift:587`, postmortem in the comment above); streaming reads deliberately stay deadline-free. Do not remove.
- Every async load guards completion with a generation counter (`sensitiveGeneration`, `RecallStore.swift:16`); new load paths must follow the same capture-and-compare pattern.
- On lock/sleep the app calls `clearSensitiveState()`/`clearSensitiveData()` (zeroes cached bytes) — hook any new decrypted-content cache into that teardown (`apps/AfterRay/Sources/AfterRayApp.swift:1097`).
- Decode artifact bytes by `contentType`, never by assumption (`DaemonClient.swift:34-35`): moments packed before thumbnails existed answer with raw IVF/AV1 frames.
- Every surface must stay drivable by `AfterRayMockData`; `RecallView` hides daemon-only chrome when callbacks are nil.

## Build / test

- `swift test` (repo root), or filter e.g. `swift test --filter DaemonWireTests`.
- Exercise surfaces with `make visual-lab` / `make settings-lab` / `make chat-lab` / `make snapshots`.

## Watch out

- `AfterRayServices` (the composition root) is **not** in this library — it lives in `apps/AfterRay/Sources/HistoryWindow.swift`.
- The packaged `.app` bundle is assembled by `scripts/build-release.sh`, not SwiftPM; don't expect `swift run afterray-app` to behave like the packaged app.
