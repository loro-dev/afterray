# AGENTS.md — apps/AfterRayVisualLab

Interactive UI development harness for the recall surfaces (root `Package.swift` executable target, product `afterray-visual-lab`). It runs the real `swift/AfterRayRecall` views against `swift/AfterRayMockData` fixtures — no daemon, no privacy permissions, no real user data. Use it for any UI work before touching the live app.

## Key file

- `Sources/AfterRayVisualLabApp.swift:5` `@main` `AfterRayVisualLabApp` — selects a surface via CLI args (`AfterRayVisualLabApp.swift:35-44`):
  - default: recall timeline; `--settings` settings chrome; `--chat` chat panel; `--onboarding` onboarding
  - `--models` opens settings on the models page; `--stream` makes the chat scenario stream tokens
  - `--stress` opens the 20K GOP timeline used for scroll/frame-budget profiling

## Run

- `make visual-lab` — recall surface
- `make visual-lab-stress` — interactive 20K GOP timeline
- `make visual-lab-stress-profile` — release 20K GOP timeline with four repeatable flicks; prints display-link cadence and synchronous handler p95/max after inertia settles
- `make settings-lab` — `--settings --models`
- `make chat-lab` — `--chat`
- `make dev-ui` — watch-mode rebuild loop over `swift/` + this target (`scripts/dev.sh --ui`)

## Invariants / watch out

- The Recall library's views take loader closures and protocol models precisely so this harness can drive them — keep new surfaces mock-drivable (see `swift/AfterRayRecall` and `swift/AfterRayMockData`).
- Mock image/thumbnail generation must stay off the main actor; synchronous `NSImage.lockFocus()` made the lab report hitches that production daemon I/O does not have.
- For CLI Instruments runs, attach to the release lab and do not allocate a PTY/TTY to `xctrace`; deferred Animation Hitches traces otherwise stall during finalization.
- For headless pixel review use `apps/AfterRayVisualSnapshots` (`make snapshots`) instead.
