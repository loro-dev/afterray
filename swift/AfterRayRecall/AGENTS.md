# AfterRayRecall — recall UI library

SwiftUI library holding everything cross-app: the recall surface, Unix-socket daemon client, wire models, and settings/chat chrome. Chat Markdown uses MarkdownUI 2.4.1 (MIT); Textual still needs Swift 6 mode. Consumed by `apps/AfterRay`, the Visual Lab, and the snapshot tool; tests and previews use `AfterRayMockData`, so views take loaders and protocol models, not a live daemon.

## Key files

- `Sources/DaemonClient.swift:148` `UnixSocketDaemonClient` (actor) — JSON-line requests over a Unix socket; `protocolVersion` (:175) checked on every response. Protocols `RecallDaemonServing` (:22), `AfterRayChatServing` (:67), `AfterRayDaemonServing` (:99) are the injection seam; `WireRequest` (:442) is the snake_case wire shape.
- `Sources/RecallStore.swift:4` `RecallStore` — `@MainActor` timeline/playhead state; `applyPlayhead` does not write `@Published playheadMs` when the clamped value is unchanged (overlay reopen must not rebuild the tree). `Sources/RecallStore.swift:302` `RecallImageRepository` (actor) — NSCache + in-flight dedup of artifact bytes.
- `Sources/RecallModels.swift` — `RecallSession` (:3), `RecallMoment` (:21), `RecallWebLink` (:155), `RecallGopRef` (:194), `ArtifactPayload` (:224); all wire models are `Codable` with explicit snake_case `CodingKeys`.
- `Sources/RecallView.swift:24` `RecallView` — main recall surface. `TranscriptCaption` overlays `recallContent`; never put it in the bottom `VStack` or it lifts `DaySummaryPanel`. History is a windowed list with writable offset compensation, total `visibleRange`, a non-Markdown estimator, reveal-only follow, and equatable panel/rows. Read [history-list-scrolling](../../context/history-list-scrolling.md) before touching it. Copy is per slot / day / loaded range.
- `Sources/ArtifactAudioPlayer.swift` — generation-guarded recall audio; the button is pause/resume, and the moment offset is used only on first load.
- `Sources/AfterRayControlModel.swift:4` — recording/search state; `Sources/AfterRayChatModel.swift` + `ChatModels.swift` — chat model; `ChatMessagePart` keeps think/tool arrival order; `ChatConversationGrouping.days` is O(n log n) and the only grouping path. `ChatComposerField` is an `NSTextView`; do not assign `string` on every SwiftUI pass (that drops undo). Paste/undo shortcuts come from the app's Edit menu, not from the view. Turn wall time is `usage_json.elapsed_ms` (and `turnStartedAtMs` while streaming), shown next to tok/s — do not use per-round `progress.elapsed_ms` as the total.
- `Sources/StreamingMarkdown.swift` + `Sources/ChatMarkdownView.swift` + `Sources/ChatMomentCitationView.swift` — MarkdownUI splitter + citations. Thumb first (`RecallThumbnailCache`), then `RecallChatPreviewCache` via `MomentGet` + still/exact GOP; time from `captured_at_ms`. Image providers refuse http/file/data. The **same parser** splits a v3 summary body in `DaySummaryLayout.markdownSections`, so chat and the day panel cannot disagree on what a heading or a citation is. A `#el<N>` fragment is deliberately outside the media regex: it renders as text, not a frame.
- `Sources/ChatAutoScrollState.swift` + `Sources/ChatScrollMetrics.swift` — read-only geometry/phase-driven chat follow; only user scrolling unfollows. Stream pinning uses `defaultScrollAnchor(.bottom)`; `scrollTo` is discrete.
- `Sources/ComputeActivity*.swift` — the compute dashboard: wire models + `ComputeIndicator` (button state) + `ComputeFormat` (all rounding, so it is testable); `ComputeActivityPresenting` + a 2s poller that runs only while watched; the panel and `ComputeActivityButton`. Design notes: [context/compute-governance.md](../../context/compute-governance.md).
- `Sources/L10n/` — UI i18n contract: [Sources/L10n/AGENTS.md](Sources/L10n/AGENTS.md).
- `Sources/AfterRaySettingsChrome.swift:5` `AfterRaySettingsModeling` + `AfterRaySettingsView` (:327) — settings UI generic over the protocol, so mock and real models share it; `downloadQueueSection` draws the models page's downloads; `downloadSourceSection` picks the Hugging Face mirror (official / hf-mirror / custom).
- `Sources/ModelDownloadQueue.swift:116` `ModelLibrary.downloadQueue` — the daemon's active-pack + waiting-ids report flattened into queue rows; `isQueued` (:160) gates per-pack buttons.
- `Sources/OcrTextLayout.swift` + `Sources/OcrTextSelectionLayer.swift` + `Sources/OcrRegionCache.swift` — selectable OCR text over the settled frame (I-beam, drag-select, ⌘C). Every non-obvious decision is in [context/ocr-text-selection.md](../../context/ocr-text-selection.md); read it before touching the mount gate or the gesture veto.
- `Sources/AppIconLookup.swift:8` — cached bundle-id → icon; `AppIconView` (:54) for rows naming an app.
- `Sources/HangWatchdog.swift:36` `HangJudge` + `OverlayVisibility` (:6) — terminates the process if the main thread stalls ~12s while the overlay is visible.
- `Tests/` (XCTest, `@testable import AfterRayRecall`) — `DaemonWireTests.swift` and `ChatWireTests.swift` pin the wire shape against the Rust daemon.

## Invariants

- The UI never opens the database or reads encryption keys (`docs/development.md:112-113`) — everything arrives via `UnixSocketDaemonClient`.
- `protocolVersion` must stay in lockstep with `PROTOCOL_VERSION: u32 = 15`; bump both on any wire change or every request fails with `protocolMismatch`.
- Compute policy is the daemon's: the Info popover's numbers come from `ComputeThresholds` on the wire and whether "Start now" appears comes from `ComputeGate.can_run_now`. Never re-derive either in Swift — the explanation and the button must not be able to drift from the gate that decides. A row shows `max(pending, backlog)` as remaining, because the queue count is a subset of the vault count.
- One duration formatter (`ComputeFormat.duration`) and one byte formatter (`AfterRayStorageSnapshot.byteCount`) across the panel, matching `human_duration` in the daemon log — the same pass must not read as two different numbers in two places.
- The dashboard shows a task's **lane** (GPU/CPU), never a per-task GPU percentage — macOS publishes no per-process GPU accounting. CPU/memory come from the worker's pid and are absent, not zero, when there is no child process.
- Concurrency: stores are `@MainActor` `ObservableObject`s; socket client and image repository are actors; daemon I/O runs in `Task.detached(priority: .userInitiated)` (`DaemonClient.swift:394,416`). Never block the main thread — the HangWatchdog kills the app.
- Unary socket reads have a 30s receive deadline (`DaemonClient.swift:587`, postmortem in the comment above); streaming reads deliberately stay deadline-free. Do not remove.
- Every async load guards completion with a generation counter (`sensitiveGeneration`, `RecallStore.swift:16`); new load paths must follow the same capture-and-compare pattern.
- On lock/sleep the app calls `clearSensitiveState()`/`clearSensitiveData()` (zeroes cached bytes) — hook any new decrypted-content cache in the suspend handler (`AfterRayApp` `afterRaySystemSessionWillSuspend`). Includes `RecallThumbnailCache`, `RecallChatPreviewCache` and `OcrRegionCache` (decrypted screen text).
- The selectable text layer mounts only after the frame has been still for `OcrTextSelectionLayer.quietDuration`; the gate is the `.task(id: textLayerKey)` key, and anything that means "the picture moved" must be folded into that key rather than handled with a new timer.
- Decode artifact bytes by `contentType`, never by assumption (`DaemonClient.swift:34-35`): moments packed before thumbnails answer with raw IVF/AV1 frames.
- Chat Markdown never loads general image URLs. Any complete `![label](afterray://moment/ID)` (standalone, indented, list-prefixed, or inline) may call `ReadThumbnail` / `MomentGet` / `ReadArtifact` / `ReadGopFrame`; http/file/data images stay selectable text, and missing captures stay clickable citations. Do not put chat-preview frames in the 360px filmstrip cache.
- A captured address only ever reaches `NSWorkspace` through `RecallWebLink`, which admits `http`/`https` alone. `RecallMoment.url` is unvalidated AX output — apps also publish `file:`, `javascript:` and private schemes there — so never open it directly.
- Every surface must stay drivable by `AfterRayMockData`; `RecallView` hides daemon-only chrome when callbacks are nil.
- **Do not attach accessibility modifiers per overlay `ForEach` item.** Collapse repeated items with `.accessibilityElement(children: .ignore)`, never `.combine`; rationale and measurements: [history-list-scrolling](../../context/history-list-scrolling.md).
- Panels with their own `ScrollView` inside the overlay must mount `.background(ScrollFenceView())`, or the global scroll monitor (`RecallView.swift:1597`) eats their gesture phases and kills momentum.
- Chat transcript is an eager `VStack` (do not reintroduce `LazyVStack`: variable-height rows land the viewport in empty space). Streaming follow is `defaultScrollAnchor(.bottom)` only; never `scrollTo` from a geometry tick or per-token `onChange`. Idle frames never force-scroll; only AppKit live-scroll may disable following.
- Summary exports use `slot_summary_export` and `SummaryExportFileStore`: parsed P2 JSON and user-opened Markdown use UUID files in a `0700` temp directory with `0600` files, cleared on launch, lock/sleep and exit. The title copy and Markdown actions both use `DaySummaryClipboard.slotText`, so they cannot drift.
- **Three card shapes decode at once** (`DaySlotSummary`): v1 `bullets`, v2 `threads`, v3 `details` (one Markdown document). `expandedSections` prefers `details`; the older two must keep rendering, and `schemaVersion` — not which field is nil — is what a shape claims.
- Download progress belongs to the queue section alone; pack rows and the assistant panel show status and actions only, gated on `isQueued(packID:)`. A global "a download is running" flag is what once stopped a second pack from ever being queued.

## Build / test

- `swift test` (repo root), or filter e.g. `swift test --filter DaemonWireTests`.
- `make check-i18n` — see [Sources/L10n/AGENTS.md](Sources/L10n/AGENTS.md).
- Exercise surfaces with `make visual-lab` / `make settings-lab` / `make chat-lab` / `make snapshots`.

## Watch out

- `AfterRayServices` (the composition root) is **not** in this library — it lives in `apps/AfterRay/Sources/HistoryWindow.swift`. Shipped chat is `ChatWindowController` (`apps/AfterRay/Sources/ChatWindow.swift`), not `AfterRayChatOverlay`.
- The packaged `.app` bundle is assembled by `scripts/build-release.sh`, not SwiftPM; don't expect `swift run afterray-app` to behave like the packaged app.
