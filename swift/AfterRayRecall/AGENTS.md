# AfterRayRecall — recall UI library

Dependency-free (system frameworks only) SwiftUI library holding everything cross-app: the recall surface, the Unix-socket daemon client, wire models, and settings/chat chrome. Consumed by `apps/AfterRay`, the Visual Lab, and the snapshot tool; tests and previews drive it through `AfterRayMockData`, so views take loader closures and protocol models, not a live daemon.

## Key files

- `Sources/DaemonClient.swift:148` `UnixSocketDaemonClient` (actor) — JSON-line requests over a Unix socket; `protocolVersion` (:175) checked on every response. Protocols `RecallDaemonServing` (:22), `AfterRayChatServing` (:67), `AfterRayDaemonServing` (:99) are the injection seam; `WireRequest` (:442) is the snake_case wire shape.
- `Sources/RecallStore.swift:4` `RecallStore` — `@MainActor` timeline/playhead state; `Sources/RecallStore.swift:302` `RecallImageRepository` (actor) — NSCache + in-flight dedup of artifact bytes.
- `Sources/RecallModels.swift` — `RecallSession` (:3), `RecallMoment` (:21), `RecallGopRef` (:133), `ArtifactPayload` (:163); all `Codable` with explicit snake_case `CodingKeys`.
- `Sources/RecallView.swift:9` `RecallView` — the main recall surface (`RecallPalette` at :2211).
- `Sources/AfterRayControlModel.swift:4` — recording/search state; `Sources/AfterRayChatModel.swift:46` chat model behind `AfterRayChatModeling` (:4).
- `Sources/StreamingMarkdown.swift` + `Sources/ChatMomentCitationView.swift` — streaming-safe chat Markdown and protocol-backed screenshot citations; only standalone `![label](afterray://moment/ID)` loads media.
- `Sources/ChatAutoScrollState.swift` + `Sources/ChatScrollObserver.swift` — macOS 14 chat bottom-follow state machine and the narrow AppKit live-scroll/geometry bridge; content growth follows only until the user scrolls away.
- `Sources/AfterRaySettingsChrome.swift:5` `AfterRaySettingsModeling` + `AfterRaySettingsView` (:327) — settings UI generic over the protocol, so mock and real models share it; `downloadQueueSection` draws the models page's downloads; `downloadSourceSection` picks the Hugging Face mirror (official / hf-mirror / custom).
- `Sources/ModelDownloadQueue.swift:116` `ModelLibrary.downloadQueue` — the daemon's active-pack + waiting-ids report flattened into queue rows; `isQueued` (:160) gates per-pack buttons.
- `Sources/AppIconLookup.swift:8` — cached bundle-id → icon; `AppIconView` (:54) for rows naming an app.
- `Sources/HangWatchdog.swift:36` `HangJudge` + `OverlayVisibility` (:6) — terminates the process if the main thread stalls ~12s while the overlay is visible.
- `Tests/` (XCTest, `@testable import AfterRayRecall`) — `DaemonWireTests.swift` and `ChatWireTests.swift` pin the wire shape against the Rust daemon.

## Invariants

- The UI never opens the database or reads encryption keys (`docs/development.md:112-113`) — everything arrives via `UnixSocketDaemonClient`.
- `protocolVersion` must stay in lockstep with `PROTOCOL_VERSION: u32 = 13`; bump both on any wire change or every request fails with `protocolMismatch`.
- Concurrency: stores are `@MainActor` `ObservableObject`s; socket client and image repository are actors; daemon I/O runs in `Task.detached(priority: .userInitiated)` (`DaemonClient.swift:394,416`). Never block the main thread — the HangWatchdog kills the app.
- Unary socket reads have a 30s receive deadline (`DaemonClient.swift:587`, postmortem in the comment above); streaming reads deliberately stay deadline-free. Do not remove.
- Every async load guards completion with a generation counter (`sensitiveGeneration`, `RecallStore.swift:16`); new load paths must follow the same capture-and-compare pattern.
- On lock/sleep the app calls `clearSensitiveState()`/`clearSensitiveData()` (zeroes cached bytes) — hook any new decrypted-content cache in (`apps/AfterRay/Sources/AfterRayApp.swift:1097`).
- Decode artifact bytes by `contentType`, never by assumption (`DaemonClient.swift:34-35`): moments packed before thumbnails answer with raw IVF/AV1 frames.
- Chat Markdown never loads general image URLs. Only `afterray://moment` image references may call `ReadThumbnail`; http/file/data images stay selectable text, and missing captures stay clickable citations.
- Every surface must stay drivable by `AfterRayMockData`; `RecallView` hides daemon-only chrome when callbacks are nil.
- Panels with their own `ScrollView` inside the overlay must mount `.background(ScrollFenceView())`, or the global scroll monitor (`RecallView.swift:1597`) eats their gesture phases and kills momentum.
- Streaming chat scrolls to a stable bottom sentinel without per-token animation. Only AppKit live-scroll notifications may disable following; token/image/layout growth must never be interpreted as user intent.
- Summary exports use `slot_summary_export` and `SummaryExportFileStore`: parsed P2 only, UUID JSON files in a `0700` temp directory with `0600` files, cleared on launch, lock/sleep and exit.
- Download progress belongs to the queue section alone; pack rows and the assistant panel show status and actions only, gated on `isQueued(packID:)`. A global "a download is running" flag is what once stopped a second pack from ever being queued.

## Build / test

- `swift test` (repo root), or filter e.g. `swift test --filter DaemonWireTests`.
- Exercise surfaces with `make visual-lab` / `make settings-lab` / `make chat-lab` / `make snapshots`.

## Watch out

- `AfterRayServices` (the composition root) is **not** in this library — it lives in `apps/AfterRay/Sources/HistoryWindow.swift`.
- The packaged `.app` bundle is assembled by `scripts/build-release.sh`, not SwiftPM; don't expect `swift run afterray-app` to behave like the packaged app.
