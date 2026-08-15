# AGENTS.md — apps/AfterRayVisualLab

Interactive UI development harness for the recall surfaces (root `Package.swift` executable target, product `afterray-visual-lab`). It runs the real `swift/AfterRayRecall` views against `swift/AfterRayMockData` fixtures — no daemon, no privacy permissions, no real user data. Use it for any UI work before touching the live app.

## Key file

- `Sources/AfterRayVisualLabApp.swift:5` `@main` `AfterRayVisualLabApp` — selects a surface via CLI args (`AfterRayVisualLabApp.swift:35-44`):
  - default: recall timeline; `--settings` settings chrome; `--chat` chat panel; `--onboarding` onboarding
  - `--models` opens settings on the models page; `--stream` makes the chat scenario stream tokens

## Run

- `make visual-lab` — recall surface
- `make settings-lab` — `--settings --models`
- `make chat-lab` — `--chat`
- `make dev-ui` — watch-mode rebuild loop over `swift/` + this target (`scripts/dev.sh --ui`)

## Invariants / watch out

- The Recall library's views take loader closures and protocol models precisely so this harness can drive them — keep new surfaces mock-drivable (see `swift/AfterRayRecall` and `swift/AfterRayMockData`).
- For headless pixel review use `apps/AfterRayVisualSnapshots` (`make snapshots`) instead.
