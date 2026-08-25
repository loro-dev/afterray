# AGENTS.md — apps/AfterRay

The shipped macOS app (`AfterRayApp` target, `afterray-app` product). It owns the app delegate, menu bar, overlay, daemon supervision, permissions, and updates; shared UI and wire logic lives in `swift/AfterRayRecall`.

## Key files

- `Sources/AfterRayApp.swift:30` — app delegate; `RecallOverlayController` (overlay panel, Carbon hotkey, screenshot yield); `AfterRayMenuBar`; `AfterRayRootView`. `AfterRayMainMenu` must retain App + **Edit**, or native editing fails. Shipped chrome uses `AfterRayCopy`; see the [i18n contract](../../swift/AfterRayRecall/Sources/L10n/AGENTS.md). Screenshot yield: [screenshot-hotkey-yield](../../docs/decisions/active/product/2026-08-21-screenshot-hotkey-yield.md).
- `Sources/DaemonSupervisor.swift:6` — spawns/owns `afterrayd` and helper binaries, resolves socket/data dirs; dev layout detected via `.afterray-dev` parent in `developmentRepoRoot()` (:276)
- `Sources/HistoryWindow.swift:12` `AfterRayServices` shares timeline and summary-history stores; `AfterRayStandardWindowPresence` owns Dock/Cmd-Tab for pop-outs; `HistoryWindowController` hosts history.
- `Sources/ChatWindow.swift:10` `ChatWindowController` — standalone chat window; stream lives on `AfterRayServices.shared.chat`
- `Sources/AfterRaySettings.swift:25` `AfterRaySettingsController` / real `AfterRaySettingsModel` (:47)
- Others: `SystemPermissionCoordinator.swift`, `AfterRayUpdater.swift` (Sparkle), `AfterRayOnboarding.swift`, `AfterRayCliInstall.swift`, `AfterRayInstallLocation.swift`, `AfterRayMenuBarIcon.swift`, `OnboardingExclusions.swift`, `OverlayOpenRoute.swift` (`ScreenshotUIProcess`)

## Invariants

- **Use AppKit `AfterRayMain`, never a SwiftUI `App`:** an `LSUIElement` SwiftUI scene replaces the Edit menu and silently breaks native editing shortcuts.
- The app never opens the database or touches encryption keys — all data flows through `UnixSocketDaemonClient` over protocol 18, which must match `afterray-protocol`.
- On lock/sleep, `.afterRaySystemSessionWillSuspend` clears store/control/chat, closes chat, and clears image/thumbnail/preview caches. Hook every decrypted-content cache into this.
- Overlay keeps its tree: `orderOut`; `present()` only `orderFront`s; move only to a new screen; post `DidOpen` next turn; first paint activates; hide parks NOW; host stays non-opaque.
- **⇧⌘Space yields to screenshots.** Unregister Carbon on ⇧⌘3/4/5/6 *before* Space; do not handle this in the hotkey callback. Details: [screenshot-hotkey-yield](../../docs/decisions/active/product/2026-08-21-screenshot-hotkey-yield.md).
- The overlay, history window, and chat window must share `AfterRayServices.shared` stores — never construct a private `RecallStore` or `AfterRayChatModel`.
- `RecallView` alone owns the opaque history backdrop; `AfterRayRootView` stays transparent. An outer backdrop lags a fast flick to NOW and can leave a black screen.
- Pop-outs retain their `NSWindow`; every `show()` ensures daemon/refresh. Chat uses `sizingOptions = [.minSize]` or resize snaps back.
- Native chat toolbar owns sidebar/title/new/more in the traffic-light row with standard `.unified` margins; hosted chat sets `showsHeader: false` to prevent duplicate chrome.
- Chat is standalone: overlay hide does not stop it; citations may reopen moments; top-bar Ask calls `startNew(draft:)` before send.
- `AfterRayStandardWindowPresence`: `.regular` while History or Chat is visible/miniaturized; `.accessory` only when the last one closes.
- **The compute dashboard is opt-in and off by default** (`AfterRayPreferences.computeDashboardEnabled`). Menu item, overlay button, and poll all follow `afterRayPreferencesDidChange`.
- **Settings and the compute dashboard are windows, not overlays** — same retained-`NSWindow` pattern as History/Chat. Opening any of them calls `dismissForStandardWindow()`. Register every new window in `resignIfLast`. Hosted panels use `style: .window` so they do not draw a second card.
- **Poll lifecycles belong to the window controller, not the view.** These windows are `orderOut`-ed; `onDisappear` never fires. `ComputeActivityWindowController` starts/stops `AfterRayServices.shared.compute` on show/close.
- Daemon refresh overwrites `AfterRayPreferences.recordAudio`. Require microphone TCC only when an audio input exists; no input must not block Screen & System Audio.
- **Microphone consent is explicit and optional.** Bootstrap requests only Screen Recording and Accessibility. The mic row or later audio toggle calls `AVCaptureDevice.requestAccess` after a click; never ledger `.notDetermined` or show its Settings drag card. Don't Allow proceeds with system audio, while the shim omits the mic stream. Screen Recording and Accessibility remain required.
- **Permission refresh has one owner.** The Settings guide poll, app activation, manual refresh, and native mic result all refresh `SystemPermissionCoordinator` and reconcile capture. A detected grant restores the overlay; never hide a guide around stale state.

## Build / run

- `swift build --product afterray-app` / `make swift-app`; watch-mode signed dev app: `make dev`; one-shot signed bundle: `make v0`
- `swift run afterray-app` is bare; `scripts/build-release.sh` / `run-v0.sh` assemble the `.app` with Info.plist, Sparkle and helpers (rpath note: root `Package.swift:52-57`).

## Watch out

- Dev vs. packaged paths (socket, vault, logs) differ by bundle location — check `DaemonSupervisor` and the table in `docs/development.md` before hardcoding a path.
- Bundle version coupling for releases: `Resources/Info.plist` `CFBundleShortVersionString` must equal `[workspace.package].version` in `Cargo.toml`, or `build-release.sh` hard-fails.
