# AGENTS.md — apps/AfterRayVisualSnapshots

Offscreen PNG snapshot tool for the recall surfaces (root `Package.swift` executable target, product `afterray-visual-snapshots`). It renders `swift/AfterRayRecall` views on `swift/AfterRayMockData` fixtures in a hidden window — for reviewing pixels in a terminal, in CI, or from an agent. No daemon, no permissions, no window on screen.

## Key file

- `Sources/main.swift:19` `SnapshotRunner.main` — renders every `SnapshotScene.all` entry (`main.swift:46`) to `<name>.png`
- Forced `.darkAqua` appearance (`main.swift:25`) — the overlay only ever runs dark; without this, unstyled labels render black on black
- Window parked far offscreen at (-30000, -30000) (`main.swift:58`) so views lay out and `.task` blocks run without appearing on a display

## Run

- `make snapshots` — writes to `/tmp/afterray-snapshots`; override with `make snapshots OUT=/tmp/x`
- Equivalent: `swift run afterray-visual-snapshots <out-dir>`

## Watch out

- Known blind spot: the full-resolution still is drawn by an `AVSampleBufferDisplayLayer`, which does not render through `cacheDisplay(in:to:)` — chrome snapshots show every overlay over an empty picture. The `highlight-*` scenes exist to cover that gap (`main.swift:12-17`).
- Scene inventory lives in `SnapshotScene.all` in this directory's sources; add new scenes there, not ad hoc in `main.swift`.
