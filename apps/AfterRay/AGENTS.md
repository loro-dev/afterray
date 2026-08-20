# AGENTS.md — apps/AfterRay

The shipped macOS app (`AfterRayApp` target, `afterray-app` product). It owns the app delegate, menu bar, overlay, daemon supervision, permissions, and updates; shared UI and wire logic lives in `swift/AfterRayRecall`.

## Key files

- `Sources/AfterRayApp.swift:30` `@main` + app delegate; `RecallOverlayController` (Carbon hot key + status-bar-level panel); `AfterRayMenuBar`; `AfterRayRootView`. Overlay placement policy: `OverlayOpenRoute.swift` (`OverlayPanelPlacement`). `AfterRayMainMenu` is the only menu bar: App + **Edit**. Without Edit, ⌘X/⌘C/⌘V/⌘Z never become `cut:`/`copy:`/`paste:`/`undo:` in *any* field — search bar, settings, chat composer.
- `Sources/DaemonSupervisor.swift:6` — spawns/owns `afterrayd` and helper binaries, resolves socket/data dirs; dev layout detected via `.afterray-dev` parent in `developmentRepoRoot()` (:276)
- `Sources/HistoryWindow.swift:12` `AfterRayServices` (`static let shared`); `AfterRayStandardWindowPresence` (:39) Dock/Cmd-Tab for pop-outs; `HistoryWindowController` (:57)
- `Sources/ChatWindow.swift:10` `ChatWindowController` — standalone chat window; stream lives on `AfterRayServices.shared.chat`
- `Sources/AfterRaySettings.swift:25` `AfterRaySettingsController` / real `AfterRaySettingsModel` (:47)
- Others: `SystemPermissionCoordinator.swift`, `AfterRayUpdater.swift` (Sparkle), `AfterRayOnboarding.swift`, `AfterRayCliInstall.swift`, `AfterRayInstallLocation.swift`, `AfterRayMenuBarIcon.swift`, `OnboardingExclusions.swift`

## Invariants

- **The entry point is AppKit (`AfterRayMain`), never a SwiftUI `App`.** A SwiftUI `Scene` assigns its own `NSApp.mainMenu` after `applicationDidFinishLaunching`, and the generated menu has no Edit item for an `LSUIElement` app — that silently killed ⌘X/⌘C/⌘V/⌘Z in every text field in the app. Settings is an AppKit window, so the `Settings` scene bought nothing.
- The app never opens the database or touches encryption keys — all data flows through `UnixSocketDaemonClient` over protocol 14, which must match `afterray-protocol`.
- On lock/sleep, `.afterRaySystemSessionWillSuspend` clears store/control/chat, closes chat, and clears image/thumbnail/preview caches. Hook every decrypted-content cache into this.
- Overlay show is Spotlight-class: keep the hosting tree laid out (`orderOut`, not torn down), `present()` only `orderFront`s, `setFrame` only when the mouse screen moved, and post `DidOpen` / `activate` on the next run-loop turn. Do not invalidate SwiftUI on the hotkey turn.
- The overlay, history window, and chat window must share `AfterRayServices.shared` stores — never construct a private `RecallStore` or `AfterRayChatModel`.
- `RecallView` alone owns the opaque history backdrop; `AfterRayRootView` stays transparent. An outer backdrop lags a fast flick to NOW and can leave a black screen.
- Pop-outs retain their `NSWindow`; every `show()` ensures daemon/refresh. Chat uses `sizingOptions = [.minSize]` or resize snaps back.
- Native chat toolbar owns sidebar/title/new/more in the traffic-light row with standard `.unified` margins; hosted chat sets `showsHeader: false` to prevent duplicate chrome.
- Chat is standalone: overlay hide does not stop it; citations may reopen moments; top-bar Ask calls `startNew(draft:)` before send.
- `AfterRayStandardWindowPresence`: `.regular` while History or Chat is visible/miniaturized; `.accessory` only when the last one closes.
- **The compute dashboard is opt-in and off by default** (`AfterRayPreferences.computeDashboardEnabled`, toggled in Advanced settings). It exposes worker processes, lanes, queue depths and gate thresholds; the governor's automatic behaviour needs no supervision, so the surface stays hidden until asked for. The menu item and the overlay button both follow `afterRayPreferencesDidChange` — and so does the poll, or an invisible watcher keeps sampling.
- **Settings and the compute dashboard are windows, not overlays.** `AfterRaySettingsController` and `ComputeActivityWindowController` follow `HistoryWindowController`: retained `NSWindow`, frame autosave, `AfterRayStandardWindowPresence` for Dock/Cmd-Tab. Both used to render inside the recall overlay, which made changing a setting a full-screen event, left Esc ambiguous, and stacked a panel on a panel. Opening any of these (or Chat / History) calls `dismissForStandardWindow()` so the status-bar overlay cannot cover a window the hotkey then cannot dismiss. Register every new window in `resignIfLast` or closing it drops the Dock icon while another is still open.
- Panels hosted in these windows must **not** draw their own card: `AfterRaySettingsView(style: .window)` and `ComputeActivityPanel` skip the clip, stroke and close button, because a rounded card inside a rounded window is what makes a background look like it bleeds past the radius.
- **Poll lifecycles belong to the window controller, not the view.** These windows are `orderOut`-ed, not torn down, so a SwiftUI `onDisappear` never fires; a view-owned watcher polls for the life of the process. `ComputeActivityWindowController` starts/stops `AfterRayServices.shared.compute` on show/close, and the overlay button's copy rides the `afterRayRecall{DidOpen,WillHide}` notifications.
- Daemon refresh overwrites `AfterRayPreferences.recordAudio`. Require microphone TCC only when an audio input exists; no input must not block Screen & System Audio.
- **Never gate the microphone prompt behind the automatic-request ledger.** macOS lists the app in the Microphone pane only once the consent prompt is *answered*, and granting Screen Recording relaunches the app mid-prompt — so `.notDetermined` always re-asks (bootstrap, audio toggled on, or the permission gate's button). System consent alerts can sit beneath the `.statusBar` overlay; hide it before requesting.
- **A declined microphone never blocks the permission gate.** Only an unanswered (`.notDetermined`) prompt holds `allGranted`; a deny proceeds with screen + system audio, and the capture shim skips the microphone stream when TCC is not authorized — otherwise `SCStream.startCapture` fails wholesale.

## Build / run

- `swift build --product afterray-app` / `make swift-app`; watch-mode signed dev app: `make dev`; one-shot signed bundle: `make v0`
- `swift run afterray-app` is bare; `scripts/build-release.sh` / `run-v0.sh` assemble the `.app` with Info.plist, Sparkle and helpers (rpath note: root `Package.swift:52-57`).

## Watch out

- Dev vs. packaged paths (socket, vault, logs) differ by bundle location — check `DaemonSupervisor` and the table in `docs/development.md` before hardcoding a path.
- Bundle version coupling for releases: `Resources/Info.plist` `CFBundleShortVersionString` must equal `[workspace.package].version` in `Cargo.toml`, or `build-release.sh` hard-fails.
