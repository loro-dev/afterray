# AfterRayMockData — fixture models for the recall UI

Implements AfterRayRecall's model protocols with deterministic fixture data so the UI can be developed, previewed, and screenshotted without a daemon, recording permissions, or real user data. Backs the Visual Lab (`make visual-lab`, `make settings-lab`, `make chat-lab`), the snapshot tool (`make snapshots`), and parts of `AfterRayRecallTests`.

## Key files

- `Sources/RecallScenarios.swift:5` `RecallScenario` — named fixture sets including `empty`, `short`, `long`, `stress`, `processing`, `favorites`, and `search`. Entry point for labs and snapshots.
- `Sources/SettingsPreviewModel.swift:6` `SettingsPreviewModel` — `AfterRaySettingsModeling` over in-memory state.
- `Sources/ComputePreviewModel.swift` `ComputePreviewModel` + `ComputeFixtures` — the compute dashboard without a daemon. The default fixture is the awkward case (on battery, summaries held, a model resident and idle), because that is the state the panel has to read well in.
- `Sources/ChatPreviewModel.swift:25` `ChatPreviewModel` — `AfterRayChatModeling` with scripted replies. The `.thinking` fixture is think → tool → think so chat-lab shows ordered parts.
- `Sources/RecallScenarios.swift` `MockScreenText` — the strings a mock frame draws **and** the OCR boxes describing them, measured from the same table and font. `MockArtifactFactory.renderFrame` and `MockSearchData.ocrLoader` both read it; hand-written box coordinates drift the first time either side is edited.

## Invariants

- Depends only on `AfterRayRecall` (`Package.swift:40-44`); never import app/daemon code and never touch the socket, network, or filesystem outside the fixtures.
- `AfterRaySettingsModeling` gained `computeDashboardEnabled` / `setComputeDashboardEnabled`; `SettingsPreviewModel` mirrors it. When a recall protocol gains a requirement or a view gains a loader closure, update the matching preview model in the same change — labs and snapshots compile against these. Chat citation cards use `MockSearchData.thumbnailLoader` / `previewLoader` / `momentLoader`.
- Fixtures must stay safe to render anywhere: no real paths, contacts, or user content.

## Build / test

- No dedicated test target; built transitively via `swift build` / `swift test` from the repo root and exercised by the `make *-lab` and `make snapshots` loops.
