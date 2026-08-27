import AfterRayRecall
import AppKit
import Carbon.HIToolbox
import SwiftUI

private extension Notification.Name {
    static let afterRayRecallDidOpen = Notification.Name("dev.afterray.recall-did-open")
    static let afterRayRecallWillHide = Notification.Name("dev.afterray.recall-will-hide")
    static let afterRayRecallDidHide = Notification.Name("dev.afterray.recall-did-hide")
    static let afterRayRecallToggleAudio = Notification.Name("dev.afterray.recall-toggle-audio")
    static let afterRaySystemSessionWillSuspend = Notification.Name(
        "dev.afterray.system-session-will-suspend"
    )
    static let afterRaySystemSessionDidResume = Notification.Name(
        "dev.afterray.system-session-did-resume"
    )
}

@MainActor
private final class RecallOverlayLayout: ObservableObject {
    static let shared = RecallOverlayLayout()

    @Published private(set) var topSafeAreaInset: CGFloat = 0

    func update(for screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        guard inset != topSafeAreaInset else { return }
        topSafeAreaInset = inset
    }
}

/// AppKit owns the process, not a SwiftUI `App`.
///
/// A SwiftUI `Scene` assigns its own `NSApp.mainMenu` shortly after
/// `applicationDidFinishLaunching` — on the first hosting view or the first
/// activation, whichever lands first. That generated menu carries no Edit
/// item for an `LSUIElement` app, so it silently threw away the one this app
/// installs and every ⌘X/⌘C/⌘V/⌘Z/⌘A in the process stopped resolving: with
/// no Edit menu, `performKeyEquivalent` returns false and the keystroke dies
/// before it can reach the field editor. Settings is an AppKit window
/// (`AfterRaySettingsController`), so the `Settings` scene bought nothing.
// @dec:local-release-library-validation — docs/decisions/active/process/2026-08-22-local-release-library-validation.md
@main
enum AfterRayMain {
    static func main() {
        // The release pipeline executes the fully signed binary to make dyld
        // validate every linked framework. Exit before AppKit or user state is
        // initialized; a missing or runtime-invalid framework fails before this
        // branch can run.
        if ProcessInfo.processInfo.environment["AFTERRAY_PACKAGING_DYLD_PROBE"] == "1" {
            return
        }
        let app = NSApplication.shared
        MainActor.assumeIsolated {
            app.delegate = AfterRayAppDelegate.shared
        }
        app.run()
    }
}

// @dec:bounded-shutdown — docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md
/// Claims application termination synchronously and owns the one cleanup task.
/// AppKit may ask more than once while a `.terminateLater` reply is outstanding;
/// only the first caller is allowed to start teardown.
@MainActor
final class AfterRayTerminationState {
    static let shared = AfterRayTerminationState()

    private(set) var isTerminating = false
    private var cleanupTask: Task<Void, Never>?

    @discardableResult
    func begin(
        onStart: () -> Void,
        cleanup: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        onStart()
        cleanupTask = Task { @MainActor in
            await cleanup()
        }
        return true
    }

    func waitForCleanup() async {
        if let cleanupTask {
            await cleanupTask.value
        }
    }
}

/// Runs both required application-owned cleanup paths and returns only after
/// both are complete. The caller remains single-flight via
/// `AfterRayTerminationState.begin`.
@MainActor
func performAfterRayTerminationCleanup(
    exportCleanup: @escaping @MainActor @Sendable () async -> Void,
    daemonCleanup: @escaping @MainActor @Sendable () async -> Void
) async {
    async let exports: Void = exportCleanup()
    async let daemon: Void = daemonCleanup()
    _ = await (exports, daemon)
}

@MainActor
private final class AfterRayAppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.delegate` is weak, so the process has to hold this.
    static let shared = AfterRayAppDelegate()

    private var workspaceObservers: [NSObjectProtocol] = []
    private var localizationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_: Notification) {
        AfterRayLocalization.shared.bootstrapFromSystem()
        AfterRayLog.install()
        AfterRayLog.info("application launched")
        Task {
            do {
                try await SummaryExportFileStore.shared.prepareForLaunch()
            } catch {
                AfterRayLog.error("summary export cleanup failed: \(error.localizedDescription)")
            }
        }
        // Before anything else that could wedge: a hung main thread under a
        // status-bar-level, all-spaces overlay is a locked screen. The
        // watchdog samples the stall for the log, then kills the process so
        // the user gets their machine back.
        HangWatchdog.shared.start(logDirectory: AfterRayLog.directory)
        // Before the daemon, the menu bar, or any window: an app running from
        // the disk image cannot install its own updates, and moving it means
        // relaunching from the new location.
        if AfterRayInstallLocation.relocateIfNeeded() { return }
        // Ahead of both menus: they ask the updater for their item while being
        // built, and a disabled updater contributes none.
        AfterRayUpdater.shared.start()
        installAppMenu()
        AfterRayMenuBar.shared.install()
        observeSystemSessionSecurityEvents()
        RecallOverlayController.shared.start()
        // A hidden panel does not receive display-link ticks. The opt-in perf
        // run orders it front from `bootstrap()` only after permission
        // reconciliation and the initial warm timeline are complete; showing
        // it here races the bootstrap's required permission-sheet hide/show.
        AfterRayCliInstall.refreshIfStale()
        OnboardingController.shared.showIfNeeded()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        AfterRayTerminationState.shared.begin(onStart: {
            // Visible feedback and the request gate happen synchronously, before
            // the cleanup task can yield or a second Quit can arrive.
            AfterRayMenuBar.shared.remove()
            RecallOverlayController.shared.stop()
            AfterRayServices.shared.compute.stopWatching()
            AfterRaySettingsController.shared.model.pauseDownloadMonitoring()
            AfterRayServices.shared.chat.clearSensitiveState()
            DaemonSupervisor.shared.beginTermination()
        }) {
            let started = Date.now
            await performAfterRayTerminationCleanup(
                exportCleanup: {
                    let exportStarted = Date.now
                    do {
                        try await SummaryExportFileStore.shared.cleanupAll()
                        let elapsedMs = Int(Date.now.timeIntervalSince(exportStarted) * 1_000)
                        AfterRayLog.info("summary export cleanup completed in \(elapsedMs) ms")
                    } catch {
                        let elapsedMs = Int(Date.now.timeIntervalSince(exportStarted) * 1_000)
                        AfterRayLog.error(
                            "summary export cleanup failed after \(elapsedMs) ms: \(error.localizedDescription)"
                        )
                    }
                },
                daemonCleanup: {
                    await DaemonSupervisor.shared.shutdown()
                }
            )
            let elapsedMs = Int(Date.now.timeIntervalSince(started) * 1_000)
            AfterRayLog.info("application shutdown completed in \(elapsedMs) ms")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.forEach { observer in
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let localizationObserver {
            NotificationCenter.default.removeObserver(localizationObserver)
            self.localizationObserver = nil
        }
        AfterRayMenuBar.shared.remove()
        RecallOverlayController.shared.stop()
        DaemonSupervisor.shared.stop()
    }

    private func installAppMenu() {
        let copy = AfterRayLocalization.shared.copy
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: copy.menu.settings,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        if let updateItem = makeUpdateMenuItem() {
            appMenu.addItem(updateItem)
        }
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: copy.menu.quit,
            action: #selector(quitAfterRay),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        AfterRayMainMenu.install(appMenu: appMenu)
        if localizationObserver == nil {
            localizationObserver = NotificationCenter.default.addObserver(
                forName: .afterRayLocalizationDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.installAppMenu() }
            }
        }
    }

    private func makeUpdateMenuItem() -> NSMenuItem? {
        AfterRayUpdater.shared.makeMenuItem()
    }

    @objc private func openSettings() {
        AfterRaySettingsController.shared.show()
    }

    @objc private func quitAfterRay() {
        NSApp.terminate(nil)
    }

    private func observeSystemSessionSecurityEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let suspendNotifications: [(Notification.Name, String)] = [
            (NSWorkspace.sessionDidResignActiveNotification, "lock"),
            (NSWorkspace.screensDidSleepNotification, "sleep"),
            (NSWorkspace.willSleepNotification, "sleep"),
        ]
        let resumeNotifications: [Notification.Name] = [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        workspaceObservers += suspendNotifications.map { name, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    await AfterRayAppDelegate.pauseCapture(reason: reason)
                }
            }
        }
        workspaceObservers += resumeNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    AfterRayAppDelegate.resumeCapture()
                }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    await AfterRayAppDelegate.pauseCapture(reason: "lock")
                }
            }
        )
        workspaceObservers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AfterRayAppDelegate.resumeCapture()
                }
            }
        )
    }

    @MainActor
    fileprivate static func pauseCapture(reason: String) async {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        NotificationCenter.default.post(name: .afterRaySystemSessionWillSuspend, object: nil)
        DaemonSupervisor.shared.suspendForSystemLock()
        let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        _ = try? await client.recordStop(reason: reason)
    }

    @MainActor
    fileprivate static func resumeCapture() {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        DaemonSupervisor.shared.resumeAfterSystemUnlock()
        NotificationCenter.default.post(name: .afterRaySystemSessionDidResume, object: nil)
    }
}

@MainActor
private final class AfterRayMenuBar: NSObject {
    static let shared = AfterRayMenuBar()

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var computeItem: NSMenuItem?
    private var shortcut = RecallHotKeyStore.shared.hotKey
    private var preferenceObserver: NSObjectProtocol?

    private override init() {
        super.init()
        // The compute dashboard is off by default and toggled in Advanced
        // settings; the menu has to follow without being rebuilt.
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .afterRayPreferencesDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AfterRayMenuBar.shared.refreshComputeItem() }
        }
        NotificationCenter.default.addObserver(
            forName: .afterRayLocalizationDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AfterRayMenuBar.shared.reinstall() }
        }
    }

    func refreshComputeItem() {
        computeItem?.isHidden = !AfterRayPreferences.computeDashboardEnabled
    }

    func reinstall() {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        remove()
        install()
    }

    func install() {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        guard statusItem == nil else {
            refresh()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
        }

        let copy = AfterRayLocalization.shared.copy
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: copy.menu.openAfterRay,
            action: #selector(openAfterRay),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(
            title: copy.menu.settings,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let pauseItem = NSMenuItem(
            title: copy.menu.pauseCapture,
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseItem = pauseItem
        let computeItem = NSMenuItem(
            title: copy.menu.localComputation,
            action: #selector(openComputeActivity),
            keyEquivalent: ""
        )
        computeItem.target = self
        // Hidden unless the user asked for the dashboard in Advanced settings.
        computeItem.isHidden = !AfterRayPreferences.computeDashboardEnabled
        menu.addItem(computeItem)
        self.computeItem = computeItem
        let clearHour = NSMenuItem(
            title: copy.menu.deleteLastHour,
            action: #selector(deleteLastHour),
            keyEquivalent: ""
        )
        clearHour.target = self
        menu.addItem(clearHour)
        menu.addItem(.separator())
        if let updateItem = AfterRayUpdater.shared.makeMenuItem() {
            menu.addItem(updateItem)
        }
        let quitItem = NSMenuItem(
            title: copy.menu.quit,
            action: #selector(quitAfterRay),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        refresh()
        print(
            "AfterRay: menu extra installed visible=\(item.isVisible) button=\(item.button != nil)"
        )
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func captureStatusDidChange() {
        refresh()
    }

    func setShortcut(_ shortcut: RecallHotKey) {
        self.shortcut = shortcut
        refresh()
    }

    func setOverlayVisible(_: Bool) {}

    @objc private func openAfterRay() {
        RecallOverlayController.shared.show()
    }

    @objc private func openSettings() {
        AfterRaySettingsController.shared.show()
    }

    @objc private func openComputeActivity() {
        ComputeActivityWindowController.shared.show()
    }

    @objc private func toggleCapture() {
        Task {
            guard !AfterRayTerminationState.shared.isTerminating else { return }
            let control = AfterRayServices.shared.control
            guard control.canToggleRecording else { return }
            let changed = await control.toggleRecording()
            refresh()
            if !changed, let message = control.message {
                AfterRayLog.error(message, source: "menu")
            }
        }
    }

    @objc private func deleteLastHour() {
        Task {
            guard !AfterRayTerminationState.shared.isTerminating else { return }
            do {
                let result = try await UnixSocketDaemonClient(
                    socketPath: DaemonSupervisor.shared.socketPath
                ).clearHistory(scope: .lastHour)
                AfterRayLog.info("deleted \(result.deleted) moments from the last hour", source: "menu")
            } catch {
                AfterRayLog.error(error.localizedDescription, source: "menu")
            }
        }
    }

    @objc private func quitAfterRay() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let control = AfterRayServices.shared.control
        let captureIsActive = control.isCaptureSessionActive
        statusItem?.isVisible = true
        button.image = Self.icon()
        button.alphaValue = captureIsActive ? 1 : 0.46
        let copy = AfterRayLocalization.shared.copy
        let state = captureIsActive ? copy.menu.recording : copy.menu.paused
        button.toolTip = copy.menu.tooltip(state, shortcut.displayString)
        pauseItem?.title = captureIsActive ? copy.menu.pauseCapture : copy.menu.resumeCapture
        pauseItem?.isEnabled = control.canToggleRecording
    }

    private static func icon() -> NSImage {
        AfterRayMenuBarIcon.make()
    }
}

/// Transparent overlay pixels must still own the mouse. Otherwise trackpad
/// scrolls over empty timeline chrome fall through to the app behind and
/// AfterRay never sees them.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

    private func configureTransparency() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class RecallOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_: Any?) {
        RecallOverlayController.shared.hide(returnFocus: true)
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private let recallHotKeyHandler: EventHandlerUPP = { _, _, _ in
    // Spotlight-class: if Carbon already delivered on the main thread, show
    // in this run-loop turn so orderFront commits with the key event.
    let fire = {
        MainActor.assumeIsolated {
            // While the welcome window is up the press is the lesson, not a command.
            guard !OnboardingController.shared.handleHotKey() else { return }
            RecallOverlayController.shared.toggle()
        }
    }
    if Thread.isMainThread {
        fire()
    } else {
        DispatchQueue.main.async(execute: fire)
    }
    return noErr
}

@MainActor
final class RecallOverlayController: RecallHotKeyBinding {
    static let shared = RecallOverlayController()

    private var panel: RecallOverlayPanel?
    private var previousApplication: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var resignKeyObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var screenshotYieldMonitors: [Any] = []
    private var screenshotLaunchObserver: NSObjectProtocol?
    private var screenshotTerminateObserver: NSObjectProtocol?
    private var yieldingToScreenshot = false

    func start() {
        guard panel == nil else { return }

        let screen = targetScreen
        RecallOverlayLayout.shared.update(for: screen)
        let panel = RecallOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = OverlayHostingView(rootView: AfterRayRootView())
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        self.panel = panel
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Automation is launched from another foreground app. If
                // that harness retakes key focus before the delayed driver
                // starts, the panel would park and its display link would
                // never tick. This opt-in process is dedicated to the scrub
                // run; normal launches keep the resign-to-hide behaviour.
                guard ProcessInfo.processInfo.environment["AFTERRAY_UI_PERF_AUTORUN"] != "1"
                else { return }
                // A status-bar overlay covers every normal window. Losing key
                // means the user moved on — keep covering and Esc / the hotkey
                // have nothing they can reach.
                RecallOverlayController.shared.hide(returnFocus: false)
            }
        }
        registerHotKey()
        installKeyMonitor()
        installScreenshotYield()
        installScreenObserver()

        // Keep the hosting tree alive so capture can bootstrap in the
        // background, but do not order the full-screen panel in until the
        // user explicitly opens AfterRay. The frame is already the current
        // screen so the first hotkey is orderFront of a laid-out tree, not
        // the first layout of a zero-rect hosting view.
        panel.layoutIfNeeded()
        panel.orderOut(nil)
        AfterRayMenuBar.shared.setOverlayVisible(false)
    }

    var isVisible: Bool { panel?.isVisible == true }

    var currentScreen: NSScreen? {
        panel?.screen ?? targetScreen
    }

    func isOverlayWindow(_ window: NSWindow) -> Bool {
        panel === window
    }

    func makeKeyIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func stop() {
        NotificationCenter.default.post(name: .afterRayRecallWillHide, object: nil)
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        removeScreenshotYield()
        hotKey = nil
        eventHandler = nil
        keyMonitor = nil
        yieldingToScreenshot = false
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panel?.orderOut(nil)
        panel = nil
        AfterRayMenuBar.shared.setOverlayVisible(false)
    }

    func toggle() {
        if PermissionGuideController.shared.isVisible {
            PermissionGuideController.shared.hide()
            show()
            return
        }
        if panel?.isVisible == true {
            hide(returnFocus: true)
        } else {
            show()
        }
    }

    func show(navigatingTo summarySlot: DaySlotSummary? = nil) {
        present(intent: summarySlot.map { .summary($0) })
    }

    func show(navigatingToMoment momentID: String) {
        present(intent: .moment(momentID))
    }

    private func present(intent: OverlayOpenIntent? = nil) {
        guard let panel else { return }
        PermissionGuideController.shared.hide()
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        // Same-screen show is orderFront of an already-laid-out tree.
        // Activate first so Liquid Glass samples as an active window —
        // deferring it left 1–2 frames of opaque inactive material.
        // DidOpen (focus, route) still waits until after this commit.
        placeOnTargetScreen()
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        AfterRayMenuBar.shared.setOverlayVisible(true)
        OverlayVisibility.shared.set(true)
        setCapturePaused(true)
        scheduleWorkAfterFirstFrame(intent)
    }

    /// Moves the hidden (or visible) panel onto the mouse screen without
    /// forcing a display. No-op when the frame already matches, which is
    /// the hot path after start() and after a previous show on this screen.
    private func placeOnTargetScreen() {
        guard let panel else { return }
        let screen = targetScreen
        RecallOverlayLayout.shared.update(for: screen)
        let frame = screen.frame
        guard OverlayPanelPlacement.needsMove(from: panel.frame, to: frame) else { return }
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Focus and open-route run after this turn's CATransaction commits
    /// so they cannot rebuild the tree on the first painted frame.
    private func scheduleWorkAfterFirstFrame(_ intent: OverlayOpenIntent?) {
        DispatchQueue.main.async { [intent] in
            MainActor.assumeIsolated {
                RecallOverlayController.shared.completePresent(intent: intent)
            }
        }
    }

    fileprivate func completePresent(intent: OverlayOpenIntent?) {
        guard panel?.isVisible == true else { return }
        NotificationCenter.default.post(name: .afterRayRecallDidOpen, object: intent)
    }

    /// While the overlay is up it covers the screen, so anything the daemon
    /// photographed would be pixels the user is no longer looking at — and the
    /// search field's own keystrokes. Ask the daemon to skip screenshots
    /// without ending the recording session; `hide` lifts it again.
    private func setCapturePaused(_ paused: Bool) {
        Task {
            let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            do {
                _ = try await client.setCapturePaused(paused: paused, reason: "overlay")
            } catch {
                AfterRayLog.error(
                    "capture pause \(paused) failed: \(error.localizedDescription)",
                    source: "overlay"
                )
            }
        }
    }

    /// Standard windows sit below this panel. Opening one while recall is
    /// up must drop the overlay or the window appears behind a surface the
    /// hotkey can no longer dismiss.
    func dismissForStandardWindow() {
        hide(returnFocus: false)
    }

    func hide(returnFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        NotificationCenter.default.post(name: .afterRayRecallWillHide, object: nil)
        let application = returnFocus ? previousApplication : nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        AfterRayMenuBar.shared.setOverlayVisible(false)
        OverlayVisibility.shared.set(false)
        setCapturePaused(false)
        application?.activate(options: [])
        // After the window is off-screen: park the hidden tree in the live
        // presentation so the next orderFront is not one opaque history
        // frame followed by glass.
        NotificationCenter.default.post(name: .afterRayRecallDidHide, object: nil)
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Re-place while hidden so the next hotkey stays a warm
                // orderFront. A visible overlay also follows a reconnect
                // without setFrame(display: true).
                RecallOverlayController.shared.placeOnTargetScreen()
            }
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if RecallOverlayController.shared.shouldConsumeCloseKey(event) {
                RecallOverlayController.shared.closeFromKeyboard()
                return nil
            }
            if RecallOverlayController.shared.shouldConsumeAudioToggleKey(event) {
                NotificationCenter.default.post(name: .afterRayRecallToggleAudio, object: nil)
                return nil
            }
            return event
        }
    }

    /// Carbon consumes ⇧⌘Space before Screenshot can use Space to enter
    /// window mode. The chord must be unregistered on ⇧⌘3/4/5/6, not in the
    /// hotkey handler — by then the Space is already gone.
    private func installScreenshotYield() {
        let noteCenter = NSWorkspace.shared.notificationCenter
        screenshotLaunchObserver = noteCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                guard ScreenshotUIProcess.isScreenshotApp(app?.bundleIdentifier) else { return }
                RecallOverlayController.shared.beginYieldingToScreenshot()
            }
        }
        screenshotTerminateObserver = noteCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                let running = NSWorkspace.shared.runningApplications.map {
                    (bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
                }
                guard ScreenshotUIProcess.shouldResumeAfterTermination(
                    bundleIdentifier: app?.bundleIdentifier,
                    processIdentifier: app?.processIdentifier,
                    running: running
                ) else { return }
                RecallOverlayController.shared.endYieldingToScreenshot()
            }
        }

        let onEvent = { (event: NSEvent) in
            RecallOverlayController.shared.handleScreenshotYieldEvent(event)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: { event in
                onEvent(event)
                return event
            }
        ) {
            screenshotYieldMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: onEvent
        ) {
            screenshotYieldMonitors.append(global)
        }
    }

    private func removeScreenshotYield() {
        for monitor in screenshotYieldMonitors {
            NSEvent.removeMonitor(monitor)
        }
        screenshotYieldMonitors = []
        if let screenshotLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenshotLaunchObserver)
        }
        if let screenshotTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenshotTerminateObserver)
        }
        screenshotLaunchObserver = nil
        screenshotTerminateObserver = nil
    }

    fileprivate func handleScreenshotYieldEvent(_ event: NSEvent) {
        let modifiers = RecallHotKey.Modifiers(event.modifierFlags)
        if event.type == .keyDown {
            if RecallHotKeyStore.shared.hotKey.shouldYieldToSystemScreenshot(
                keyCode: event.keyCode,
                modifiers: modifiers
            ) {
                beginYieldingToScreenshot()
            }
            return
        }
        guard event.type == .flagsChanged, yieldingToScreenshot else { return }
        // Screenshot selection survives releasing ⇧⌘. Only re-arm if the
        // UI never appeared — otherwise Space would still be stolen.
        let stillHolding = modifiers.contains(.command) || modifiers.contains(.shift)
        guard !stillHolding, !screenshotUIIsRunning() else { return }
        endYieldingToScreenshot()
    }

    // @dec:screenshot-hotkey-yield — docs/decisions/active/product/2026-08-21-screenshot-hotkey-yield.md
    fileprivate func beginYieldingToScreenshot() {
        if isVisible {
            hide(returnFocus: true)
        }
        guard !yieldingToScreenshot else { return }
        yieldingToScreenshot = true
        if !RecallHotKeyStore.shared.isRecording {
            hotKeyBindingSuspend()
        }
    }

    fileprivate func endYieldingToScreenshot() {
        guard yieldingToScreenshot else { return }
        yieldingToScreenshot = false
        if !RecallHotKeyStore.shared.isRecording {
            hotKeyBindingResume()
        }
    }

    fileprivate func screenshotUIIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            ScreenshotUIProcess.isScreenshotApp($0.bundleIdentifier)
        }
    }

    fileprivate func shouldConsumeCloseKey(_ event: NSEvent) -> Bool {
        OverlayCloseKey.shouldDismiss(
            keyCode: event.keyCode,
            isCommandW: event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers == "w",
            overlayVisible: panel?.isVisible == true,
            overlayIsKey: panel?.isKeyWindow == true,
            permissionGuideVisible: PermissionGuideController.shared.isVisible
        )
    }

    fileprivate func shouldConsumeAudioToggleKey(_ event: NSEvent) -> Bool {
        guard !yieldingToScreenshot else { return false }
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
        guard event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        if panel?.firstResponder is NSTextView { return false }
        return true
    }

    fileprivate func closeFromKeyboard() {
        if PermissionGuideController.shared.isVisible {
            PermissionGuideController.shared.hide()
            return
        }
        hide(returnFocus: true)
    }

    private func registerHotKey() {
        let store = RecallHotKeyStore.shared
        store.binding = self
        guard !installHotKey(store.hotKey) else { return }
        // A shortcut saved on an older macOS can stop being available. Falling
        // back keeps the app reachable instead of silently deaf.
        if store.hotKey != .default, installHotKey(.default) {
            store.restoreDefault()
        }
    }

    // MARK: RecallHotKeyBinding

    func hotKeyBindingSuspend() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    func hotKeyBindingResume() {
        guard !yieldingToScreenshot else { return }
        installHotKey(RecallHotKeyStore.shared.hotKey)
    }

    func hotKeyBindingApply(_ candidate: RecallHotKey) -> Bool {
        installHotKey(candidate)
    }

    @discardableResult
    private func installHotKey(_ candidate: RecallHotKey) -> Bool {
        guard installHotKeyHandler() else { return false }
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(candidate.keyCode),
            carbonModifiers(candidate.modifiers),
            EventHotKeyID(signature: 0x4152_5952, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            AfterRayLog.error(
                "macOS refused \(candidate.displayString) (status \(status))",
                source: "hotkey"
            )
            return false
        }
        hotKey = reference
        AfterRayMenuBar.shared.setShortcut(candidate)
        return true
    }

    private func installHotKeyHandler() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetApplicationEventTarget(),
            recallHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        ) == noErr
    }

    private func carbonModifiers(_ modifiers: RecallHotKey.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }
}

// @dec:explicit-optional-microphone-consent — docs/decisions/active/product/2026-08-21-explicit-optional-microphone-consent.md
@MainActor
private final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private let panelSize = NSSize(width: 392, height: 214)
    private var panel: PermissionGuidePanel?
    private var permissionPollTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    func show(
        for permission: RequiredPermission,
        onGranted: @escaping @MainActor () -> Void
    ) {
        guard permission.opensSystemSettingsGuide else { return }
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(
            rootView: PermissionSettingsGuide(
                permission: permission,
                onDismiss: { [weak self] in self?.hide() }
            )
                .afterRayLocalized()
                .frame(width: panelSize.width, height: panelSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = []
        panel.contentView = hostingView

        let screen = targetScreen
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panelSize.width - 28,
            y: screen.visibleFrame.maxY - panelSize.height - 28
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.alphaValue = 0
        NSApp.unhideWithoutActivation()
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        monitorPermission(permission, onGranted: onGranted)
    }

    func showAfterOpeningSettings(
        for permission: RequiredPermission,
        onGranted: @escaping @MainActor () -> Void
    ) {
        hide()
        permissionPollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.show(for: permission, onGranted: onGranted)
        }
    }

    func hide() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func makePanel() -> PermissionGuidePanel {
        let panel = PermissionGuidePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.minSize = panelSize
        panel.maxSize = panelSize
        panel.contentMinSize = panelSize
        panel.contentMaxSize = panelSize
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.canHide = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        self.panel = panel
        return panel
    }

    private func monitorPermission(
        _ permission: RequiredPermission,
        onGranted: @escaping @MainActor () -> Void
    ) {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, self?.panel?.isVisible == true else { return }
                if permission.isGrantedNow {
                    self?.hide()
                    onGranted()
                    return
                }
            }
        }
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct PermissionSettingsGuide: View {
    let permission: RequiredPermission
    let onDismiss: () -> Void
    @ObservedObject private var hotKeys = RecallHotKeyStore.shared
    @ObservedObject private var localization = AfterRayLocalization.shared

    private var applicationURL: URL { Bundle.main.bundleURL }
    private var guide: PermissionSettingsGuideContent {
        permission.settingsGuide(copy: localization.copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permission.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(.red.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(guide.instructions)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .help(localization.copy.common.dismiss)
            }

            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AfterRay")
                        .font(.system(size: 14, weight: .semibold))
                    Text(guide.applicationAction)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: guide.actionIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.red.opacity(0.48), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if guide.allowsApplicationDrag {
                    ApplicationBundleDragSource(applicationURL: applicationURL)
                }
            }

            Text(AfterRayLocalization.shared.copy.permissions.afterGranting(hotKeys.hotKey.displayString))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 392, height: 214, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }
}

/// Uses AppKit's native file-URL pasteboard writer. System Settings' privacy
/// lists do not reliably accept SwiftUI content providers whose first declared
/// type is a dynamically generated bundle-content UTI.
private struct ApplicationBundleDragSource: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context _: Context) -> ApplicationBundleDragSourceView {
        ApplicationBundleDragSourceView(applicationURL: applicationURL)
    }

    func updateNSView(_ view: ApplicationBundleDragSourceView, context _: Context) {
        view.applicationURL = applicationURL
    }
}

private final class ApplicationBundleDragSourceView: NSView, NSDraggingSource {
    var applicationURL: URL

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func mouseDragged(with event: NSEvent) {
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 52, height: 52)
        let point = convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: point.x - 26,
            y: point.y - 26,
            width: 52,
            height: 52
        )
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for _: NSDraggingSession) -> Bool { true }
}

private struct AudioTimelineFollowTaskKey: Hashable {
    let generation: UInt64
    let isPlaying: Bool
}

private struct AfterRayRootView: View {
    // Shared with the standalone history window: both faces must observe
    // the same store, or the popped-out panel drifts from the overlay.
    @ObservedObject private var store = AfterRayServices.shared.store
    @ObservedObject private var history = AfterRayServices.shared.history
    @ObservedObject private var control = AfterRayServices.shared.control
    @ObservedObject private var audioPlayer = AfterRayServices.shared.audioPlayer
    @StateObject private var permissions = SystemPermissionCoordinator()
    @ObservedObject private var overlayLayout = RecallOverlayLayout.shared
    @ObservedObject private var computeModel = AfterRayServices.shared.compute
    /// Mirrors the Advanced-settings switch. Off by default, so the overlay's
    /// chrome cluster carries one fewer button for everyone who never asked
    /// what their machine is doing.
    @State private var showsComputeButton = AfterRayPreferences.computeDashboardEnabled
    // Chat lives in its own window (`ChatWindowController`) so a token
    // never rebuilds the recall surface. The model is shared so lock/sleep
    // can still wipe it here.
    private let chat = AfterRayServices.shared.chat
    @State private var isLive = true
    @State private var queryMode = ImmersiveQueryMode.search
    @State private var queryFocusRequest: UInt64 = 0
    private let images = AfterRayServices.shared.images

    init() {}

    var body: some View {
        RecallView(
            moments: store.moments,
            selectedMomentDetail: store.selectedMoment,
            timelineRevision: store.timelineRevision,
            timelineSpine: store.timelineSpine,
            timelineDayCoverage: store.timelineDayCoverage,
            playheadMs: Binding(
                get: { store.playheadMs },
                set: { selectTimeline(playheadMs: $0, origin: .user) }
            ),
            isLive: $isLive,
            loadState: store.loadState,
            imageLoader: { artifactID in
                try await images.data(artifactID: artifactID)
            },
            artifactLoader: { artifactID in
                try await images.data(artifactID: artifactID)
            },
            onToggleAudio: { moment in
                toggleAudio(for: moment)
            },
            isAudioPlaying: audioPlayer.isPlaying,
            isAudioBuffering: audioPlayer.isBuffering,
            audioPlaybackContext: audioPlayer.playbackContext,
            audioPlaybackTime: { audioPlayer.playbackTime },
            audioSegmentDuration: audioPlayer.playingMomentID == store.selectedMoment?.id
                ? audioPlayer.playbackDuration
                : nil,
            timelineTravelOrigin: audioPlayer.isPlaying ? .audioPlayback : nil,
            onReload: reload,
            onOpenSettings: { AfterRaySettingsController.shared.show() },
            // Dismiss first: the overlay panel is `.statusBar` level and
            // full-screen, so a browser brought forward under it would look
            // like the click did nothing. `returnFocus: false` because focus
            // belongs to the page being opened, not to whatever was frontmost
            // when recall was summoned.
            onOpenWebLink: { url in
                RecallOverlayController.shared.hide(returnFocus: false)
                NSWorkspace.shared.open(url)
            },
            onOpenCompute: showsComputeButton
                ? { ComputeActivityWindowController.shared.toggle() }
                : nil,
            computeIndicator: computeModel.indicator,
            recordingState: control.status?.recordingState,
            isChangingRecording: control.isChangingRecording,
            onToggleRecording: toggleRecording,
            chromeTopPadding: controlBarTopPadding,
            summaryHistory: history.state,
            onLoadOlderSummaryHistory: {
                Task { await history.loadNext() }
            },
            onPopOutHistory: { HistoryWindowController.shared.show() },
            onOpenSummarySlot: openSummarySlot,
            onSelectionSettled: {
                await settleSelectedRecallEvidence()
            },
            // @dec:forced-aligned-audio-transcript-cues — docs/decisions/active/product/2026-08-24-forced-aligned-audio-transcript-cues.md
            onTimelineTravelBegan: beginTimelineTravel,
            searchSession: control.searchSession,
            thumbnailLoader: { momentID in
                try await images.thumbnail(momentID: momentID).bytes
            },
            ocrLoader: { momentID in
                try await images.ocrEvidence(momentID: momentID)
            },
            onSelectSearchFrame: selectSearchFrame,
            // @dec:pointer-centered-timeline-day-window — docs/decisions/active/architecture/2026-08-22-pointer-centered-timeline-day-window.md
            onApproachTimelineEdge: { direction, anchorMs in
                await store.extendTimeline(direction: direction, aroundMs: anchorMs)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .opacity(permissions.allGranted ? 1 : 0)
        // RecallView alone owns the full-screen history backdrop because it
        // can see transient scrub state. A second backdrop here only sees the
        // settled binding and covers the live desktop during a fast flick to
        // NOW after RecallView has already removed the captured still.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ImmersiveQueryBar(
                    model: control,
                    mode: $queryMode,
                    focusRequest: queryFocusRequest,
                    onSubmit: submitQuery,
                    onOpenChat: { openChat() },
                    onStepResult: { delta in
                        guard let session = control.searchSession else { return }
                        selectSearchFrame(session.steppedIndex(by: delta))
                    },
                    onClose: { RecallOverlayController.shared.hide(returnFocus: true) }
                )
                if let message = control.message, !control.isRecording {
                    CaptureFailureBanner(message: message, onRetry: toggleRecording)
                }
            }
            .padding(.top, controlBarTopPadding)
        }
        .overlay {
            if !permissions.allGranted {
                PermissionPanel(
                    coordinator: permissions,
                    onPermissionStateChanged: {
                        Task { await reconcilePermissionState() }
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        // Tied to the overlay being *visible*, not to this view's lifetime: the
        // panel is `orderOut`-ed rather than torn down, so `onDisappear` never
        // fires and an `onAppear` watcher would poll for the life of the process
        // — the exact background load this dashboard exists to report on.
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallDidOpen)) { _ in
            if showsComputeButton { computeModel.startWatching() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallWillHide)) { _ in
            if showsComputeButton { computeModel.stopWatching() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayPreferencesDidChange)) { _ in
            let enabled = AfterRayPreferences.computeDashboardEnabled
            guard enabled != showsComputeButton else { return }
            showsComputeButton = enabled
            // Start or stop the button's own poll with the switch, not just its
            // visibility: an invisible watcher is the whole failure mode this
            // panel exists to warn about.
            if enabled {
                if RecallOverlayController.shared.isVisible { computeModel.startWatching() }
            } else {
                computeModel.stopWatching()
            }
        }
        .onExitCommand {
            audioPlayer.stop()
            RecallOverlayController.shared.hide(returnFocus: true)
        }
        .onChange(of: isLive) { _, live in
            if live { audioPlayer.stop() }
        }
        .onChange(of: control.status?.recordingState, initial: true) { _, _ in
            AfterRayMenuBar.shared.captureStatusDidChange()
        }
        .onChange(of: control.isChangingRecording) { _, _ in
            AfterRayMenuBar.shared.captureStatusDidChange()
        }
        .task {
            await bootstrap()
        }
        .task {
            await keepDaemonAlive()
        }
        .task(id: AudioTimelineFollowTaskKey(
            generation: audioPlayer.generation,
            isPlaying: audioPlayer.isPlaying
        )) {
            await followAudioTimeline()
        }
        .task(id: control.status?.recordingState) {
            while !Task.isCancelled,
                  !AfterRayTerminationState.shared.isTerminating,
                  control.isCaptureSessionActive || control.isChangingRecording
            {
                try? await Task.sleep(for: .seconds(control.isWaitingToRecord ? 1 : 5))
                guard !Task.isCancelled else { return }
                await control.refreshStatus()
                if control.isRecording {
                    await store.refreshTimeline(preservingSelection: !isLive)
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: control.searchSession == nil)
        .animation(.easeOut(duration: 0.14), value: control.isAsking)
        .animation(.easeOut(duration: 0.14), value: control.askAnswer == nil)
        .animation(.easeOut(duration: 0.18), value: permissions.allGranted)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await reconcilePermissionState()
            }
        }
        // Posted on the turn *after* orderFront so this work cannot hitch
        // the overlay's first frame (focus, live-route, compute watch).
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallDidOpen)) { notification in
            audioPlayer.stop()
            Task { await history.refreshNewest() }
            if permissions.allGranted, !AfterRaySettingsController.shared.isVisible {
                queryFocusRequest &+= 1
            }
            // A search outlives the overlay being dismissed, and its filmstrip
            // comes back parked on the frame it was left on. Going live anyway
            // put "NOW" on the clock above a still from hours ago, so reopening
            // into a live search lands back on the selected result instead.
            let selectedSearch = control.searchSession?.selectedFrame != nil
            switch OverlayOpenRoute.resolve(
                intent: notification.object as? OverlayOpenIntent,
                hasSelectedSearch: selectedSearch
            ) {
            case .summary(let slot):
                openSummarySlot(slot)
            case .moment(let momentID):
                openCitedMoment(momentID)
            case .selectedSearch:
                guard let session = control.searchSession else { return }
                selectSearchFrame(session.selectedIndex)
            case .live:
                enterLive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallWillHide)) { _ in
            audioPlayer.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallDidHide)) { _ in
            // Park only the default reopen. A selected search must survive
            // hide so the next first frame is still the filmstrip, not NOW.
            if OverlayOpenRoute.shouldParkLiveOnHide(
                hasSelectedSearch: control.searchSession?.selectedFrame != nil
            ) {
                enterLive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallToggleAudio)) { _ in
            guard !isLive,
                  let moment = store.selectedMoment,
                  moment.id == audioPlayer.playingMomentID || moment.audioSegment != nil
            else { return }
            toggleAudio(for: moment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionDidResume)) { _ in
            Task {
                guard !AfterRayTerminationState.shared.isTerminating else { return }
                guard await startDaemonOrReportFailure() != nil else { return }
                permissions.refresh()
                if permissions.allGranted,
                   !DaemonSupervisor.shared.isCapturePausedForSystemLock,
                   !AfterRayTerminationState.shared.isTerminating
                {
                    _ = await control.ensureRecording()
                }
                async let timeline: Void = store.refreshTimeline(preservingSelection: !isLive)
                async let summaries: Void = history.reload()
                _ = await (timeline, summaries)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionWillSuspend)) { _ in
            audioPlayer.clearSensitiveData()
            store.clearSensitiveState()
            history.clearSensitiveState()
            control.clearSensitiveState()
            chat.clearSensitiveState()
            ChatWindowController.shared.close()
            clearRecallDecodedImageCache()
            RecallThumbnailCache.shared.clearSensitiveData()
            RecallChatPreviewCache.shared.clearSensitiveData()
            OcrRegionCache.shared.clearSensitiveData()
            Task { await images.clearSensitiveData() }
            Task { try? await SummaryExportFileStore.shared.cleanupAll() }
        }
        .afterRayLocalized()
    }

    private func beginTimelineTravel(_ origin: RecallTimelineTravelOrigin) {
        if RecallTimelineTravelPolicy.invalidatesAudio(origin) {
            audioPlayer.stop()
        }
    }

    // @dec:settled-search-evidence-and-off-main-audio-prepare — docs/decisions/active/architecture/2026-08-25-settled-search-evidence-and-off-main-audio-prepare.md
    /// Search travel may cross many unloaded day windows. Only the result that
    /// survives the view's quiet period is allowed to open a window and hydrate
    /// transcript evidence.
    private func settleSelectedRecallEvidence() async {
        if let expectedMomentID = control.searchSession?.selectedFrame?.momentId {
            if store.selectedMoment?.id == expectedMomentID {
                await store.hydrateSelectedEvidence()
            } else {
                await store.openMoment(id: expectedMomentID)
            }
            guard !Task.isCancelled,
                  control.searchSession?.selectedFrame?.momentId == expectedMomentID,
                  store.selectedMoment?.id == expectedMomentID
            else { return }
        } else {
            await store.hydrateSelectedEvidence()
            guard !Task.isCancelled else { return }
        }

        if let moment = store.selectedMoment {
            audioPlayer.updateEvidence(from: moment)
        }
        await store.prefetchAdjacentTimelineDays()
    }

    /// Playback evidence has its own request lifetime. Automatic timeline
    /// following deliberately suppresses selection hydration, so tying cues to
    /// that task could leave fast playback permanently on the sparse index row.
    private func toggleAudio(for moment: RecallMoment) {
        audioPlayer.toggle(moment: moment)
        guard let context = audioPlayer.playbackContext else { return }
        let expectedGeneration = audioPlayer.generation
        let expectedSegmentID = context.segmentID
        Task {
            guard let detail = try? await images.moment(id: moment.id),
                  !Task.isCancelled,
                  audioPlayer.generation == expectedGeneration,
                  audioPlayer.playbackContext?.segmentID == expectedSegmentID
            else { return }
            audioPlayer.updateEvidence(
                from: detail,
                generation: expectedGeneration
            )
        }
    }

    private func selectTimeline(
        playheadMs: Int64,
        origin: RecallTimelineTravelOrigin
    ) {
        beginTimelineTravel(origin)
        guard origin != .audioPlayback || audioPlayer.isPlaying else { return }
        store.select(playheadMs: playheadMs)
    }

    // @dec:audio-playback-follows-timeline — docs/decisions/active/product/2026-08-24-audio-playback-follows-timeline.md
    private func followAudioTimeline() async {
        guard audioPlayer.isPlaying else { return }
        while !Task.isCancelled, audioPlayer.isPlaying {
            guard let position = audioPlayer.timelinePlaybackPosition else { return }
            let target = AudioTimelineFollow.target(
                for: position,
                moments: store.moments
            )
            if let target, target.moment.id != audioPlayer.playingMomentID {
                audioPlayer.followTimeline(to: target.moment)
                selectTimeline(
                    playheadMs: target.moment.capturedAtMs,
                    origin: .audioPlayback
                )
            }

            let interval = AudioTimelineFollow.nextCheckInterval(
                position: position,
                target: target
            )
            do {
                try await Task.sleep(
                    for: .milliseconds(Int64((interval * 1_000).rounded(.up)))
                )
            } catch {
                return
            }
        }
    }

    private func openSummarySlot(_ slot: DaySlotSummary) {
        isLive = false
        audioPlayer.stop()
        if let anchor = slot.anchorMomentId {
            if !store.selectLoaded(momentID: anchor) {
                Task {
                    await store.openMoment(id: anchor)
                    if store.selectedMoment?.id != anchor {
                        store.select(playheadMs: slot.slotStartMs)
                    }
                }
            }
        } else {
            Task {
                await store.ensureTimelineContains(ms: slot.slotStartMs)
                store.select(playheadMs: slot.slotStartMs)
                await store.prefetchAdjacentTimelineDays()
            }
        }
    }

    private var controlBarTopPadding: CGFloat {
        RecallGeometry.controlBarTopPadding(safeAreaTop: overlayLayout.topSafeAreaInset)
    }

    private func bootstrap() async {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        guard await startDaemonOrReportFailure() != nil else { return }
        // A daemon that outlived a crashed app may still carry the overlay's
        // capture pause; a fresh launch always starts with the overlay hidden.
        do {
            let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            if let settings = try? await client.settings() {
                AfterRayLocalization.shared.apply(stored: settings.uiLanguage)
            }
            _ = try await client.setCapturePaused(paused: false, reason: "launch")
        } catch {
            AfterRayLog.info("bootstrap: clearing capture pause failed: \(error.localizedDescription)")
        }
        // Let the welcome window have the screen to itself: stacking macOS
        // permission sheets on top of it makes the first launch a pile-up.
        await OnboardingController.shared.waitUntilFinished()
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        // The overlay is `.statusBar`; system consent alerts sit under it.
        // Hide only if onboarding just ordered it in — later launches keep
        // the overlay down until the hotkey, so we must not pop it here.
        let overlayWasVisible = RecallOverlayController.shared.isVisible
        if overlayWasVisible {
            RecallOverlayController.shared.hide(returnFocus: false)
        }
        await permissions.requestInitialPermissionsOnce()
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        if overlayWasVisible {
            RecallOverlayController.shared.show()
        }
        if permissions.allGranted {
            AfterRayLog.info("bootstrap: permissions granted, ensuring recording")
            _ = await control.ensureRecording()
        } else {
            AfterRayLog.info(
                "bootstrap: permissions incomplete screen=\(permissions.screenRecording) mic=\(permissions.microphone) ax=\(permissions.accessibility) recordAudio=\(permissions.recordsAudio)"
            )
            await control.refreshStatus()
        }
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        async let timeline: Void = store.loadTimeline()
        async let summaries: Void = history.reload()
        _ = await (timeline, summaries)
        await store.prefetchAdjacentTimelineDays()
        // The in-process scrub driver waits for this real overlay and display
        // link. Normal launches never carry the opt-in environment variable.
        // Keeping the first show after bootstrap also keeps permission checks
        // from parking the panel after the driver has already started.
        if ProcessInfo.processInfo.environment["AFTERRAY_UI_PERF_AUTORUN"] == "1" {
            RecallOverlayController.shared.show()
        }
    }

    /// Every permission completion path converges here: returning from System
    /// Settings, the guide's live poll, the manual refresh button, and the
    /// native microphone prompt. This keeps the UI gate and capture startup on
    /// one current snapshot instead of letting the guide hide around stale
    /// coordinator state.
    private func reconcilePermissionState() async {
        guard !AfterRayTerminationState.shared.isTerminating else { return }
        permissions.refresh()
        guard await startDaemonOrReportFailure() != nil else { return }
        if permissions.allGranted {
            _ = await control.ensureRecording()
            await store.refreshTimeline(preservingSelection: !isLive)
        } else {
            await control.refreshStatus()
        }
    }

    private func toggleRecording() {
        Task {
            guard !AfterRayTerminationState.shared.isTerminating else { return }
            let changed = await control.toggleRecording()
            if changed { await store.refreshTimeline(preservingSelection: !isLive) }
        }
    }

    private func reload() {
        Task {
            guard !AfterRayTerminationState.shared.isTerminating else { return }
            guard await startDaemonOrReportFailure() != nil else { return }
            async let status: Void = control.refreshStatus()
            async let timeline: Void = store.refreshTimeline(preservingSelection: !isLive)
            async let summaries: Void = history.refreshNewest()
            _ = await (status, timeline, summaries)
        }
    }

    private func keepDaemonAlive() async {
        while !Task.isCancelled, !AfterRayTerminationState.shared.isTerminating {
            if let restarted = await startDaemonOrReportFailure(), restarted {
                permissions.refresh()
                if permissions.allGranted,
                   !DaemonSupervisor.shared.isCapturePausedForSystemLock,
                   !AfterRayTerminationState.shared.isTerminating
                {
                    _ = await control.ensureRecording()
                } else {
                    await control.refreshStatus()
                }
                async let timeline: Void = store.refreshTimeline(preservingSelection: !isLive)
                async let summaries: Void = history.refreshNewest()
                _ = await (timeline, summaries)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Starts afterrayd. Returns whether this call launched a new process,
    /// or `nil` when startup failed and the user-visible error was recorded.
    @discardableResult
    private func startDaemonOrReportFailure() async -> Bool? {
        guard !AfterRayTerminationState.shared.isTerminating else { return nil }
        do {
            return try await DaemonSupervisor.shared.startIfNeeded()
        } catch let error as RuntimeError where !error.isUserVisibleFailure {
            return nil
        } catch {
            store.reportFailure(error.localizedDescription)
            await control.refreshStatus()
            return nil
        }
    }

    /// Runs the query and lands on the newest match without a second click.
    /// Recall almost always means "the thing I just had open".
    private func submitSearch() {
        Task {
            audioPlayer.stop()
            guard let frame = await control.search() else { return }
            enterHistory()
            await store.openMoment(id: frame.momentId)
        }
    }

    private func selectSearchFrame(_ index: Int) {
        guard let frame = control.selectFrame(at: index) else { return }
        audioPlayer.stop()
        enterHistory()
        // Loaded rows are an O(1) dictionary lookup and may present at once.
        // An unloaded result can imply a full day-window recenter, so the
        // selection-settle task opens only the final result after quiet.
        _ = store.selectLoaded(momentID: frame.momentId)
    }

    private func enterHistory() {
        guard isLive else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isLive = false
        }
    }

    /// Returning to NOW is one state transition: the timeline's live flag and
    /// the shared playhead must agree before SwiftUI renders the next frame.
    private func enterLive() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.selectLatestMoment()
            isLive = true
        }
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        Task {
            await store.loadTimeline(
                containingMs: nowMs,
                preservingSelection: false
            )
            await store.prefetchAdjacentTimelineDays()
        }
    }

    /// One input, two destinations. Search stays inline; a question hands the
    /// text to the chat model and opens the full panel, because an answer needs
    /// room the single line does not have.
    private func submitQuery() {
        switch queryMode {
        case .search:
            submitSearch()
        case .ask:
            let question = control.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return }
            control.searchQuery = ""
            openChat(draft: question, send: true, startsNewConversation: true)
        }
    }

    private func openChat(
        draft: String = "",
        send: Bool = false,
        startsNewConversation: Bool = false
    ) {
        control.dismissSearch()
        ChatWindowController.shared.show(
            draft: draft,
            send: send,
            startsNewConversation: startsNewConversation
        )
    }

    /// A citation from the standalone chat window. The overlay comes up on
    /// this moment; the chat window stays put so the stream can keep going.
    private func openCitedMoment(_ momentID: String) {
        audioPlayer.stop()
        control.dismissSearch()
        enterHistory()
        if !store.selectLoaded(momentID: momentID) {
            Task { await store.openMoment(id: momentID) }
        }
    }
}

private struct PermissionPanel: View {
    @ObservedObject var coordinator: SystemPermissionCoordinator
    let onPermissionStateChanged: () -> Void
    @ObservedObject private var hotKeys = RecallHotKeyStore.shared
    @ObservedObject private var localization = AfterRayLocalization.shared

    private var copy: AfterRayCopy { localization.copy }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Rectangle()
                            .fill(RecallPalette.ray)
                            .frame(width: 18, height: 2)
                        Text(copy.permissions.eyebrow)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                    }
                    .foregroundStyle(RecallPalette.ray)
                    Text(coordinator.microphoneRequired && !coordinator.microphoneDeclined
                         ? copy.permissions.threeRequired
                         : copy.permissions.twoRequired)
                        .font(.title2.weight(.semibold))
                    Text(permissionSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 9) {
                    ForEach(RequiredPermission.allCases) { permission in
                        if permission != .microphone || coordinator.recordsAudio || coordinator.microphone {
                            permissionRow(permission)
                        }
                    }
                }

                Text(copy.permissions.afterChanging(hotKeys.hotKey.displayString))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if coordinator.isRequesting {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(copy.permissions.waitingApproval)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button(copy.permissions.checkPermissions) {
                            permissionStateChanged()
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(RecallPalette.ray)
                    }
                }
            }
            .padding(28)
            .frame(width: 500)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        }
        .afterRayLocalized()
    }

    private var permissionSummary: String {
        if !coordinator.recordsAudio {
            return copy.permissions.audioOffSummary
        }
        if !coordinator.hasMicrophoneInput {
            return copy.permissions.noMicSummary
        }
        if coordinator.microphoneDeclined {
            return copy.permissions.micDeclinedSummary
        }
        return copy.permissions.allThreeSummary
    }

    private func permissionRow(_ permission: RequiredPermission) -> some View {
        let granted = isGranted(permission)
        let unavailable = permission == .microphone && !coordinator.hasMicrophoneInput
        return HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .frame(width: 22)
                .foregroundStyle(unavailable ? Color.secondary : (granted ? Color.green : Color.red))
            Text(permission.title(copy))
                .font(.callout.weight(.medium))
            Spacer()
            if unavailable {
                Label(copy.permissions.noInputDevice, systemImage: "minus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if granted {
                Label(copy.permissions.allowed, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(microphoneActionTitle(permission)) {
                    Task {
                        // The overlay is a full-screen `.statusBar`-level
                        // panel; the system consent alert can be presented
                        // beneath it, which reads as the click doing nothing.
                        let microphoneWasUndetermined = coordinator.microphoneUndetermined
                        RecallOverlayController.shared.hide(returnFocus: false)
                        await coordinator.requestAgain(permission)
                        onPermissionStateChanged()
                        switch SystemPermissionPolicy.gateFollowUp(
                            permission: permission,
                            granted: isGranted(permission),
                            allGranted: coordinator.allGranted,
                            microphoneWasUndetermined: microphoneWasUndetermined,
                            microphoneDeclined: coordinator.microphoneDeclined
                        ) {
                        case .returnToOverlay:
                            RecallOverlayController.shared.show()
                        case .systemSettingsGuide:
                            PermissionGuideController.shared.showAfterOpeningSettings(
                                for: permission,
                                onGranted: {
                                    permissionStateChanged()
                                    RecallOverlayController.shared.show()
                                }
                            )
                            coordinator.openSettings(for: permission)
                        case .systemSettings:
                            coordinator.openSettings(for: permission)
                        }
                    }
                }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func isGranted(_ permission: RequiredPermission) -> Bool {
        switch permission {
        case .screenRecording: coordinator.screenRecording
        case .microphone: coordinator.microphone
        case .accessibility: coordinator.accessibility
        }
    }

    private func permissionStateChanged() {
        coordinator.refresh()
        onPermissionStateChanged()
    }

    private func microphoneActionTitle(_ permission: RequiredPermission) -> String {
        if permission == .microphone, coordinator.microphoneUndetermined {
            return copy.permissions.allowAccess
        }
        return copy.permissions.openSettings
    }
}

/// One line for both ways of asking the vault a question. It stays one line in
/// either mode — the chat panel is where an answer goes, and it opens on send
/// or on the chat button, never merely because you pressed Tab.
private struct ImmersiveQueryBar: View {
    @ObservedObject var model: AfterRayControlModel
    @ObservedObject private var localization = AfterRayLocalization.shared
    @Environment(\.afterRayCopy) private var environmentCopy
    @Binding var mode: ImmersiveQueryMode

    private var copy: AfterRayCopy { localization.copy }
    let focusRequest: UInt64
    let onSubmit: () -> Void
    let onOpenChat: () -> Void
    let onStepResult: (Int) -> Void
    let onClose: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleMode) {
                HStack(spacing: 5) {
                    queryModeIcon
                    Text(mode.title(copy))
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(mode == .ask ? RecallPalette.ray : .white.opacity(0.86))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
                .recallHoverFill(in: Capsule())
            }
            .buttonStyle(RecallGlassPressStyle())
            .help("\(mode.toggleHelp(copy)) (Tab)")
            .accessibilityLabel(copy.recall.inputMode)
            .accessibilityValue(mode.title(copy))
            .accessibilityHint(mode.toggleHelp(copy))

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)

            HStack(spacing: 8) {
                TextField(mode.placeholder(copy), text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .focused($isInputFocused)
                    .onSubmit(onSubmit)
                    .onKeyPress(keys: [.tab], phases: .down) { _ in
                        toggleMode()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onClose()
                        return .handled
                    }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.searchQuery.isEmpty {
                    Button(action: clearInput) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(copy.recall.clear)
                }
            }
            .frame(width: 268)

            if let session = model.searchSession {
                searchTally(session)
            }

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)

            Button(action: onOpenChat) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 26, height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .recallHoverFill(
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
            .buttonStyle(RecallGlassPressStyle())
            .help(copy.recall.openChat)
            .accessibilityLabel(copy.recall.openChat)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(copy.recall.closeAfterRay)
        }
        .padding(.horizontal, 14)
        .frame(height: RecallGeometry.overlayChromeButtonSize)
        .recallGlass(in: .capsule)
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            // The hosting tree stays mounted while the NSPanel is hidden, so
            // FocusState may still be true from the previous opening. Reset it
            // before requesting focus again or SwiftUI can treat the request as
            // a no-op and leave the panel itself as first responder.
            isInputFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            isInputFocused = true
        }
    }

    /// Search and Ask share one slot. Both glyphs stay mounted so the swap
    /// can cross-fade instead of popping — hover/click is frequent, so the
    /// motion stays short and the label still names the state.
    private var queryModeIcon: some View {
        ZStack {
            Image(systemName: ImmersiveQueryMode.search.symbol)
                .opacity(mode == .search ? 1 : 0)
                .scaleEffect(mode == .search ? 1 : 0.25)
                .blur(radius: mode == .search ? 0 : 4)
            Image(systemName: ImmersiveQueryMode.ask.symbol)
                .opacity(mode == .ask ? 1 : 0)
                .scaleEffect(mode == .ask ? 1 : 0.25)
                .blur(radius: mode == .ask ? 0 : 4)
        }
        .frame(width: 11, height: 11)
        .animation(.easeOut(duration: 0.18), value: mode)
        .accessibilityHidden(true)
    }

    private func toggleMode() {
        withAnimation(.easeOut(duration: 0.18)) {
            mode.toggle()
        }
        isInputFocused = true
    }

    private func clearInput() {
        model.searchQuery = ""
        model.dismissSearch()
    }

    /// Where you are in the result set, and how big it is. Two numbers because
    /// hits and frames differ — one frame can match several times over.
    private func searchTally(_ session: RecallSearchSession) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.positionLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                Text(session.tallyLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .fixedSize()

            // Pointing the way the strip runs: older matches lie to its left,
            // newer to its right, as on the timeline.
            HStack(spacing: 2) {
                stepButton(symbol: "chevron.left", help: copy.recall.olderMatch, delta: 1)
                    .disabled(session.selectedIndex >= session.frames.count - 1)
                stepButton(symbol: "chevron.right", help: copy.recall.newerMatch, delta: -1)
                    .disabled(session.selectedIndex == 0)
            }
        }
    }

    private func stepButton(symbol: String, help: String, delta: Int) -> some View {
        Button { onStepResult(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.78))
        .help(help)
    }

}

private struct CaptureFailureBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(3)
            Button(AfterRayLocalization.shared.copy.common.retry, action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 520)
        .recallGlass(in: .rounded(8))
        .help(message)
    }
}

private struct RecordingButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(isRecording ? Color.red.opacity(0.72) : Color.white.opacity(0.09), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
