# AGENTS.md — apps/AfterRay

The shipped macOS app (`AfterRayApp` executable target in the root `Package.swift`, product `afterray-app`). It owns everything the recall library deliberately does not: the app delegate, menu-bar item, full-screen overlay `NSPanel`, daemon process supervision, onboarding/permissions, and Sparkle updates. All UI and wire logic lives in `swift/AfterRayRecall`; this target wires it to a live daemon.

## Key files

- `Sources/AfterRayApp.swift:30` `@main` + app delegate; `RecallOverlayController` (:401, Carbon hot key + status-bar-level panel); `AfterRayMenuBar` (:216); `AfterRayRootView` (:945)
- `Sources/DaemonSupervisor.swift:6` — spawns/owns `afterrayd` and helper binaries, resolves socket/data dirs; dev layout detected via `.afterray-dev` parent in `developmentRepoRoot()` (:276)
- `Sources/HistoryWindow.swift:12` `AfterRayServices` (`static let shared`); `AfterRayStandardWindowPresence` (:39) Dock/Cmd-Tab for pop-outs; `HistoryWindowController` (:57)
- `Sources/ChatWindow.swift:10` `ChatWindowController` — standalone chat window; stream lives on `AfterRayServices.shared.chat`
- `Sources/AfterRaySettings.swift:25` `AfterRaySettingsController` / real `AfterRaySettingsModel` (:47)
- Others: `SystemPermissionCoordinator.swift`, `AfterRayUpdater.swift` (Sparkle), `AfterRayOnboarding.swift`, `AfterRayCliInstall.swift`, `AfterRayInstallLocation.swift`, `AfterRayMenuBarIcon.swift`, `OnboardingExclusions.swift`

## Invariants

- The app never opens the database or touches encryption keys — all data flows through `UnixSocketDaemonClient` over protocol 12, which must match `afterray-protocol`.
- Sensitive-state teardown on screen lock/sleep: `.afterRaySystemSessionWillSuspend` → `store`/`control`/`chat.clearSensitiveState()` + close the chat window + `images.clearSensitiveData()` (`AfterRayApp.swift:1143-1150`). Hook any new decrypted-content cache into this.
- The overlay, history window, and chat window must share `AfterRayServices.shared` stores — never construct a private `RecallStore` or `AfterRayChatModel`.
- `RecallView` exclusively owns the opaque history backdrop because it sees transient scrub state. `AfterRayRootView` must stay transparent; an outer backdrop lags a fast flick to NOW and produces a black screen after the still unmounts.
- Pop-out controllers retain their `NSWindow`. Every `show()`, including reuse, must ensure the daemon and force-refresh. A first-open connection refusal must not strand the window on `.empty`. Chat hosting must use `sizingOptions = [.minSize]` or resize snaps back.
- Chat is a standalone window. Overlay hide / Escape must not call `chat.stop()` or close it. A moment citation may show the overlay (`OverlayOpenIntent.moment`) without destroying the chat window.
- `AfterRayStandardWindowPresence`: `.regular` while History or Chat is visible/miniaturized; `.accessory` only when the last one closes.
- `AfterRaySettingsController.show()` forces the overlay visible first (`AfterRaySettings.swift:33-38`); settings render inside the recall panel.
- `AfterRayPreferences.recordAudio` (UserDefaults, `AfterRaySettings.swift:9-22`) is only a pre-daemon fallback; the daemon's `AppSettings` overwrites it on refresh.

## Build / run

- `swift build --product afterray-app` / `make swift-app`; watch-mode signed dev app: `make dev`; one-shot signed bundle: `make v0`
- `swift run afterray-app` is a bare binary — the `.app` bundle (Info.plist, Sparkle.framework, helper binaries in `Contents/Helpers`) is assembled by `scripts/build-release.sh` / `scripts/run-v0.sh` (see the linker rpath note in root `Package.swift:52-57`)

## Watch out

- Dev vs. packaged paths (socket, vault, logs) differ by bundle location — check `DaemonSupervisor` and the table in `docs/development.md` before hardcoding a path.
- Bundle version coupling for releases: `Resources/Info.plist` `CFBundleShortVersionString` must equal `[workspace.package].version` in `Cargo.toml`, or `build-release.sh` hard-fails.
