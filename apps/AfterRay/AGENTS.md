# AGENTS.md — apps/AfterRay

The shipped macOS app (`AfterRayApp` executable target in the root `Package.swift`, product `afterray-app`). It owns everything the recall library deliberately does not: the app delegate, menu-bar item, full-screen overlay `NSPanel`, daemon process supervision, onboarding/permissions, and Sparkle updates. All UI and wire logic lives in `swift/AfterRayRecall`; this target wires it to a live daemon.

## Key files

- `Sources/AfterRayApp.swift:29` `@main` + app delegate; `RecallOverlayController` (:393, Carbon hot key + status-bar-level panel); `AfterRayMenuBar` (:208); `AfterRayRootView` (:903)
- `Sources/DaemonSupervisor.swift:6` — spawns/owns `afterrayd` and helper binaries, resolves socket/data dirs; dev layout detected via `.afterray-dev` parent in `developmentRepoRoot()` (:276)
- `Sources/HistoryWindow.swift:12` `AfterRayServices` — composition root (`static let shared`); `HistoryWindowController` (:39) is the pop-out history window
- `Sources/AfterRaySettings.swift:25` `AfterRaySettingsController` / real `AfterRaySettingsModel` (:47)
- Others: `SystemPermissionCoordinator.swift`, `AfterRayUpdater.swift` (Sparkle), `AfterRayOnboarding.swift`, `AfterRayCliInstall.swift`, `AfterRayInstallLocation.swift`, `AfterRayMenuBarIcon.swift`, `OnboardingExclusions.swift`

## Invariants

- The app never opens the database or touches encryption keys — all data flows through `UnixSocketDaemonClient` over the versioned Unix socket (`swift/AfterRayRecall/Sources/DaemonClient.swift:149`, `protocolVersion = 7`, must match `crates/afterray-protocol/src/lib.rs:8`).
- Sensitive-state teardown on screen lock/sleep: `.afterRaySystemSessionWillSuspend` → `store`/`control`/`chat.clearSensitiveState()` + `images.clearSensitiveData()` (`AfterRayApp.swift:1097-1104`). Hook any new decrypted-content cache into this.
- The overlay and the history window must share `AfterRayServices.shared` stores — never construct a private `RecallStore`.
- `AfterRaySettingsController.show()` forces the overlay visible first (`AfterRaySettings.swift:33-38`); settings render inside the recall panel.
- `AfterRayPreferences.recordAudio` (UserDefaults, `AfterRaySettings.swift:9-22`) is only a pre-daemon fallback; the daemon's `AppSettings` overwrites it on refresh.

## Build / run

- `swift build --product afterray-app` / `make swift-app`; watch-mode signed dev app: `make dev`; one-shot signed bundle: `make v0`
- `swift run afterray-app` is a bare binary — the `.app` bundle (Info.plist, Sparkle.framework, helper binaries in `Contents/Helpers`) is assembled by `scripts/build-release.sh` / `scripts/run-v0.sh` (see the linker rpath note in root `Package.swift:52-57`)

## Watch out

- Dev vs. packaged paths (socket, vault, logs) differ by bundle location — check `DaemonSupervisor` and the table in `docs/development.md` before hardcoding a path.
- Bundle version coupling for releases: `Resources/Info.plist` `CFBundleShortVersionString` must equal `[workspace.package].version` in `Cargo.toml`, or `build-release.sh` hard-fails.
