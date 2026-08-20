# AGENTS.md — scripts/

Shell/Swift tooling for the dev loop, signed + notarized releases, Sparkle publishing, and model downloads. The root `Makefile` is the entry point for all of it (`make dev`, `make v0`, `make release`, `make publish`); these scripts are the implementations. Human-facing docs: `docs/development.md` and `docs/releasing.md` (both kept accurate to these scripts).

## Dev loop

- `check-i18n.sh` — static chrome i18n gate (`make check-i18n`); see `swift/AfterRayRecall/Sources/L10n/AGENTS.md`.
- `dev.sh` — watch-mode rebuild loop; change fingerprint via `stat` + `shasum` (dev.sh:57). `--ui` watches only Swift UI + mock data and runs the Visual Lab instead of the app. An explicit `AFTERRAY_DATA_DIR` is forwarded through LaunchServices on every relaunch.
- `run-v0.sh` — builds shim + Rust workspace (release) and the app (debug — mixed configs are deliberate), assembles and signs `.afterray-dev/AfterRay.app`. Dev vault data lives in `.afterray/`, dev bundle/socket in `.afterray-dev/` (both gitignored); `--ephemeral` uses a throwaway vault.
- `open-dev.sh` / `stop-dev.sh` — reopen/quit the dev bundle (bundle id `dev.afterray.app`).

## Release

- `build-release.sh` — full pipeline: version checks, assemble `AfterRay.app` by hand (SwiftPM emits bare binaries), sign, notarize, staple, DMG + zip into `dist/`. Modes: default / `--skip-notarization` / `--local`.
- `publish-release.sh` — uploads zip + DMG to R2 bucket `afterray-releases` under `artifacts/`, then updates the `releases.json` index last (publish-release.sh:36-38) so a partial failure leaves installs on the previous release.
- `tag-release.sh` — after appcast verification, creates and pushes annotated `v<version>` at the exact published `origin/main` commit.
- `fetch-sparkle-tools.sh` — Sparkle 2.9.5 tools (`sign_update`, `generate_keys`) into `.afterray-dev/sparkle-tools/`, tarball SHA-256 pinned (fetch-sparkle-tools.sh:10-13). Once per machine.

## Docs gate

- `docs-gate/` — `make docs-sync`, run by `make test`; coverage and limits: [decisions/README.md](../docs/decisions/README.md#what-the-gate-checks).
- **Node ≥22.6 runs TypeScript directly**: no dependencies, `package.json`, or `node_modules`; never put this runtime on a product path.
- A red anchor hash means a decision was not re-read when its code changed. Re-read it, then `node scripts/docs-gate/main.ts --write` and commit the sidecar diff — the diff is the confirmation. Never hand-edit a sidecar.

## Invariants

- Sparkle compares only `CFBundleVersion` = `git rev-list --count HEAD` (build-release.sh:117, override `AFTERRAY_BUILD_NUMBER`); stamped into the assembled bundle only — never hand-edit the source plist.
- `Info.plist` `CFBundleShortVersionString` must equal `[workspace.package].version` in `Cargo.toml`, and bundle id must be `dev.afterray.app` — the release dies otherwise (build-release.sh:122-136).
- arm64-only (build-release.sh:96); every shipped binary is `lipo`-verified.
- Signing is inside-out, never `--deep`; Sparkle's `Autoupdate`/`Updater.app` are signed individually (build-release.sh:379+). Sparkle XPCServices/Headers are pruned from the embedded framework — the app is not sandboxed.
- The Sparkle update zip is built from the *stapled* bundle — the notarization ticket must be in the archive or offline first-launch fails Gatekeeper.
- A release tag is created only after the public appcast contains the matching version and build; tags never move.
- Dev builds need a stable signing identity or TCC (Screen Recording) permission resets on every rebuild (run-v0.sh:183+); ad-hoc fallback uses a fixed identifier + designated requirement.
- Script style: `set -Eeuo pipefail`, exit 64 for usage errors, guard every `rm -rf` with a path-prefix check.

## Commands

- `make check-i18n` — static i18n gate; also runs from `make check` and `make test`
- `make dev` / `make dev-ui` / `make v0` / `make v0-daemon` / `make open` / `make stop`
- `make release-preflight` (needs explicit `AFTERRAY_CODESIGN_IDENTITY` + `AFTERRAY_NOTARY_PROFILE`; checks remote release-index collisions before a costly build) / `make release` (runs that preflight) / `make release-local` (needs neither)
- `make verify-release MANIFEST=dist/AfterRay-<version>-arm64.json` / `make publish-dry-run MANIFEST=…` / `make publish MANIFEST=…` / `make tag-release MANIFEST=…` — production steps always use one explicit manifest; never select an artifact by `dist/` ordering. Tag only after publish and public appcast verification.
- `make models` → `download-models/download.sh` — pure wrapper over `afterray download` (builds the CLI first if missing); override pack with `AFTERRAY_DOWNLOAD_ONLY`, dir with `AFTERRAY_MODEL_DIR`.

## Watch out

- `download-models/afterray_model_worker.py` and `download_huggingface_model.py` are **legacy and unused** — no Python anywhere in model download or inference. Don't resurrect them.
- `bench-*.swift`, `bench-recall-pipeline.sh`, `verify-gop-e2e.sh`, `prove-av1-decode.swift`, `t2-eval.py` are manual diagnostics, not part of `make test`.
- `make build` builds the capture shim first — the daemon needs its binary at `apps/AfterRayCaptureShim/.build/release/` (or `AFTERRAY_CAPTURE_SHIM`).
