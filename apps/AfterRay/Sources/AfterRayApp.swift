import AfterRayRecall
import AppKit
import Carbon.HIToolbox
import SwiftUI

private extension Notification.Name {
    static let afterRayRecallDidOpen = Notification.Name("dev.afterray.recall-did-open")
    static let afterRayRecallWillHide = Notification.Name("dev.afterray.recall-will-hide")
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
        topSafeAreaInset = screen.safeAreaInsets.top
    }
}

@main
struct AfterRayApp: App {
    @NSApplicationDelegateAdaptor(AfterRayAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AfterRaySettingsScene()
        }
        .windowResizability(.contentSize)
    }
}

private struct AfterRaySettingsScene: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AfterRaySettingsView(
            model: AfterRaySettingsController.shared.model,
            onClose: { dismiss() }
        )
    }
}

@MainActor
private final class AfterRayAppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_: Notification) {
        AfterRayLog.install()
        AfterRayLog.info("application launched")
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
        AfterRayCliInstall.refreshIfStale()
        OnboardingController.shared.showIfNeeded()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            RecallOverlayController.shared.stop()
            await DaemonSupervisor.shared.shutdown()
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
        AfterRayMenuBar.shared.remove()
        RecallOverlayController.shared.stop()
        DaemonSupervisor.shared.stop()
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
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
            title: "Quit AfterRay",
            action: #selector(quitAfterRay),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
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
        NotificationCenter.default.post(name: .afterRaySystemSessionWillSuspend, object: nil)
        DaemonSupervisor.shared.suspendForSystemLock()
        let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        _ = try? await client.recordStop(reason: reason)
    }

    @MainActor
    fileprivate static func resumeCapture() {
        DaemonSupervisor.shared.resumeAfterSystemUnlock()
        NotificationCenter.default.post(name: .afterRaySystemSessionDidResume, object: nil)
    }
}

@MainActor
private final class AfterRayMenuBar: NSObject {
    static let shared = AfterRayMenuBar()

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var isRecording = false
    private var shortcut = RecallHotKeyStore.shared.hotKey

    private override init() {
        super.init()
    }

    func install() {
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

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open AfterRay",
            action: #selector(openAfterRay),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let pauseItem = NSMenuItem(
            title: "Pause Capture",
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)
        self.pauseItem = pauseItem
        let clearHour = NSMenuItem(
            title: "Delete Last Hour",
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
            title: "Quit AfterRay",
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

    func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
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

    @objc private func toggleCapture() {
        Task {
            let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            do {
                if isRecording {
                    _ = try await daemon.recordStop(reason: "menu")
                    isRecording = false
                } else {
                    _ = try await daemon.recordStart()
                    isRecording = true
                }
                refresh()
            } catch {
                AfterRayLog.error(error.localizedDescription, source: "menu")
            }
        }
    }

    @objc private func deleteLastHour() {
        Task {
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
        statusItem?.isVisible = true
        button.image = Self.icon()
        button.alphaValue = isRecording ? 1 : 0.46
        let state = isRecording ? "AfterRay is recording" : "AfterRay is paused"
        button.toolTip = "\(state) · press \(shortcut.displayString) to open"
        pauseItem?.title = isRecording ? "Pause Capture" : "Resume Capture"
    }

    private static func icon() -> NSImage {
        AfterRayMenuBarIcon.make()
    }
}

/// Transparent overlay pixels must still own the mouse. Otherwise trackpad
/// scrolls over empty timeline chrome fall through to the app behind and
/// AfterRay never sees them.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
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
    DispatchQueue.main.async {
        // While the welcome window is up the press is the lesson, not a command.
        guard !OnboardingController.shared.handleHotKey() else { return }
        RecallOverlayController.shared.toggle()
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
    private var keyMonitor: Any?

    func start() {
        guard panel == nil else { return }

        let panel = RecallOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = OverlayHostingView(rootView: AfterRayRootView())
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
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
                if AfterRaySettingsController.shared.isPresented { return }
                RecallOverlayController.shared.hide(returnFocus: false)
            }
        }
        registerHotKey()
        installKeyMonitor()

        // Keep the hosting tree alive so capture can bootstrap in the
        // background, but do not order the full-screen panel in until the
        // user explicitly opens AfterRay.
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
        hotKey = nil
        eventHandler = nil
        keyMonitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
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

    func show() {
        guard let panel else { return }
        PermissionGuideController.shared.hide()
        NotificationCenter.default.post(name: .afterRayRecallDidOpen, object: nil)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        let screen = targetScreen
        RecallOverlayLayout.shared.update(for: screen)
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(panel)
        AfterRayMenuBar.shared.setOverlayVisible(true)
        OverlayVisibility.shared.set(true)
    }

    func hide(returnFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        NotificationCenter.default.post(name: .afterRayRecallWillHide, object: nil)
        let application = returnFocus ? previousApplication : nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        AfterRayMenuBar.shared.setOverlayVisible(false)
        OverlayVisibility.shared.set(false)
        application?.activate(options: [])
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
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

    fileprivate func shouldConsumeCloseKey(_ event: NSEvent) -> Bool {
        if PermissionGuideController.shared.isVisible {
            return event.keyCode == 53
        }
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
        if event.keyCode == 53 { return true }
        return event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers == "w"
    }

    fileprivate func shouldConsumeAudioToggleKey(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
        guard event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        if panel?.firstResponder is NSTextView { return false }
        return true
    }

    fileprivate func closeFromKeyboard() {
        if AfterRaySettingsController.shared.isPresented {
            AfterRaySettingsController.shared.hide()
            return
        }
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

@MainActor
private final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private let panelSize = NSSize(width: 392, height: 214)
    private var panel: PermissionGuidePanel?
    private var permissionPollTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    func show(for permission: RequiredPermission) {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(
            rootView: PermissionSettingsGuide(
                permission: permission,
                onDismiss: { [weak self] in self?.hide() }
            )
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
        monitorPermission(permission)
    }

    func showAfterOpeningSettings(for permission: RequiredPermission) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.show(for: permission)
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

    private func monitorPermission(_ permission: RequiredPermission) {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, self?.panel?.isVisible == true else { return }
                if permission.isGrantedNow {
                    self?.hide()
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

    private var applicationURL: URL { Bundle.main.bundleURL }
    private var guide: PermissionSettingsGuideContent { permission.settingsGuide }

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
                .help("Dismiss")
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

            Text("After granting access, press \(hotKeys.hotKey.displayString) to return.")
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

private struct AfterRayRootView: View {
    // Shared with the standalone history window: both faces must observe
    // the same store, or the popped-out panel drifts from the overlay.
    @ObservedObject private var store = AfterRayServices.shared.store
    @ObservedObject private var control = AfterRayServices.shared.control
    @ObservedObject private var audioPlayer = AfterRayServices.shared.audioPlayer
    @StateObject private var permissions = SystemPermissionCoordinator()
    @ObservedObject private var overlayLayout = RecallOverlayLayout.shared
    @ObservedObject private var settings = AfterRaySettingsController.shared
    // The overlay observes chat directly. Keeping it non-observed here stops a
    // token from rebuilding the entire recall surface underneath the panel.
    private let chat = AfterRayServices.shared.chat
    @State private var isLive = true
    @State private var isChatPresented = false
    @State private var queryMode = ImmersiveQueryMode.search
    private let images = AfterRayServices.shared.images

    init() {}

    var body: some View {
        RecallView(
            moments: store.moments,
            playheadMs: Binding(
                get: { store.playheadMs },
                set: { store.select(playheadMs: $0) }
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
                audioPlayer.toggle(moment: moment)
            },
            isAudioPlaying: audioPlayer.isPlaying,
            isAudioBuffering: audioPlayer.isBuffering,
            playingAudioArtifactID: audioPlayer.playingArtifactID,
            onReload: reload,
            onOpenSettings: { AfterRaySettingsController.shared.show() },
            recordingState: control.status?.recordingState,
            isChangingRecording: control.isChangingRecording,
            onToggleRecording: toggleRecording,
            chromeTopPadding: controlBarTopPadding,
            daySummary: store.daySummary,
            summaryHistory: store.summaryHistory,
            summaryHistoryHasMore: store.summaryHistoryHasMore,
            isLoadingSummaryHistory: store.isLoadingSummaryHistory,
            onLoadOlderSummaryHistory: {
                Task { await store.loadOlderSummaryHistory() }
            },
            onPopOutHistory: { HistoryWindowController.shared.show() },
            onVisibleDayChange: { dayMs in
                Task { await store.loadDaySummary(dayMs: dayMs) }
            },
            searchSession: control.searchSession,
            thumbnailLoader: { momentID in
                try await images.thumbnail(momentID: momentID).bytes
            },
            ocrLoader: { momentID in
                try await images.ocrEvidence(momentID: momentID)
            },
            onSelectSearchFrame: selectSearchFrame
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(permissions.allGranted ? 1 : 0)
        .background(
            isLive || !permissions.allGranted
                ? Color.clear
                : Color(red: 0.025, green: 0.022, blue: 0.026)
        )
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ImmersiveQueryBar(
                    model: control,
                    mode: $queryMode,
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
                PermissionPanel(coordinator: permissions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .overlay {
            if settings.isPresented {
                AfterRaySettingsOverlay(
                    model: settings.model,
                    onClose: { settings.hide() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay {
            if isChatPresented {
                AfterRayChatOverlay(
                    model: chat,
                    onClose: { isChatPresented = false },
                    onOpenMoment: openChatMoment
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: settings.isPresented)
        .animation(.easeOut(duration: 0.16), value: isChatPresented)
        .onExitCommand {
            if isChatPresented {
                isChatPresented = false
                return
            }
            audioPlayer.stop()
            RecallOverlayController.shared.hide(returnFocus: true)
        }
        .onChange(of: isLive) { _, live in
            if live { audioPlayer.stop() }
        }
        .onChange(of: control.isRecording, initial: true) { _, isRecording in
            AfterRayMenuBar.shared.setRecording(isRecording)
        }
        .task(id: audioPrefetchKey) {
            audioPlayer.prefetch(artifactID: audioPrefetchKey.isEmpty ? nil : audioPrefetchKey)
        }
        .task {
            await bootstrap()
        }
        .task {
            await keepDaemonAlive()
        }
        .task(id: control.status?.recordingState) {
            while !Task.isCancelled, control.isCaptureSessionActive || control.isChangingRecording {
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
                guard await startDaemonOrReportFailure() != nil else { return }
                permissions.refresh()
                if permissions.allGranted {
                    _ = await control.ensureRecording()
                    await store.refreshTimeline(preservingSelection: !isLive)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallDidOpen)) { _ in
            audioPlayer.stop()
            // A search outlives the overlay being dismissed, and its filmstrip
            // comes back parked on the frame it was left on. Going live anyway
            // put "NOW" on the clock above a still from hours ago, so reopening
            // into a live search lands back on the selected result instead.
            if let session = control.searchSession, session.selectedFrame != nil {
                selectSearchFrame(session.selectedIndex)
                return
            }
            isLive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallWillHide)) { _ in
            audioPlayer.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallToggleAudio)) { _ in
            guard !isLive, let moment = store.selectedMoment, moment.hasVisibleTranscript, moment.audioArtifactId != nil else { return }
            audioPlayer.toggle(moment: moment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionDidResume)) { _ in
            Task {
                guard await startDaemonOrReportFailure() != nil else { return }
                permissions.refresh()
                if permissions.allGranted, !DaemonSupervisor.shared.isCapturePausedForSystemLock {
                    _ = await control.ensureRecording()
                }
                await store.refreshTimeline(preservingSelection: !isLive)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionWillSuspend)) { _ in
            audioPlayer.stop()
            store.clearSensitiveState()
            control.clearSensitiveState()
            chat.clearSensitiveState()
            isChatPresented = false
            clearRecallDecodedImageCache()
            Task { await images.clearSensitiveData() }
        }
    }

    private var controlBarTopPadding: CGFloat {
        RecallGeometry.controlBarTopPadding(safeAreaTop: overlayLayout.topSafeAreaInset)
    }

    private var audioPrefetchKey: String {
        guard !isLive, let moment = store.selectedMoment, moment.hasVisibleTranscript, let artifactID = moment.audioArtifactId else { return "" }
        return artifactID
    }

    private func bootstrap() async {
        guard await startDaemonOrReportFailure() != nil else { return }
        // Let the welcome window have the screen to itself: stacking macOS
        // permission sheets on top of it makes the first launch a pile-up.
        await OnboardingController.shared.waitUntilFinished()
        await permissions.requestInitialPermissionsOnce()
        if permissions.allGranted {
            AfterRayLog.info("bootstrap: permissions granted, ensuring recording")
            _ = await control.ensureRecording()
        } else {
            AfterRayLog.info(
                "bootstrap: permissions incomplete screen=\(permissions.screenRecording) mic=\(permissions.microphone) ax=\(permissions.accessibility) recordAudio=\(permissions.recordsAudio)"
            )
            await control.refreshStatus()
        }
        await store.loadTimeline()
    }

    private func toggleRecording() {
        Task {
            let changed = await control.toggleRecording()
            if changed { await store.refreshTimeline(preservingSelection: !isLive) }
        }
    }

    private func reload() {
        Task {
            guard await startDaemonOrReportFailure() != nil else { return }
            async let status: Void = control.refreshStatus()
            async let timeline: Void = store.refreshTimeline(preservingSelection: !isLive)
            _ = await (status, timeline)
        }
    }

    private func keepDaemonAlive() async {
        while !Task.isCancelled {
            if let restarted = await startDaemonOrReportFailure(), restarted {
                permissions.refresh()
                if permissions.allGranted, !DaemonSupervisor.shared.isCapturePausedForSystemLock {
                    _ = await control.ensureRecording()
                } else {
                    await control.refreshStatus()
                }
                await store.refreshTimeline(preservingSelection: !isLive)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Starts afterrayd. Returns whether this call launched a new process,
    /// or `nil` when startup failed and the user-visible error was recorded.
    @discardableResult
    private func startDaemonOrReportFailure() async -> Bool? {
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

    private func openSearchHit(_ hit: RecallSearchHit) {
        control.dismissSearch()
        enterHistory()
        Task { await store.openSearchHit(hit) }
    }

    /// Runs the query and lands on the newest match without a second click.
    /// Recall almost always means "the thing I just had open".
    private func submitSearch() {
        Task {
            guard let frame = await control.search() else { return }
            enterHistory()
            await store.openMoment(id: frame.momentId)
        }
    }

    private func selectSearchFrame(_ index: Int) {
        guard let frame = control.selectFrame(at: index) else { return }
        enterHistory()
        // Stepping through results stays cheap: only fall back to a full
        // timeline reload when the frame is not already in memory.
        if !store.selectLoaded(momentID: frame.momentId) {
            Task { await store.openMoment(id: frame.momentId) }
        }
    }

    private func enterHistory() {
        guard isLive else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isLive = false
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
            openChat(draft: question, send: true)
        }
    }

    private func openChat(draft: String = "", send: Bool = false) {
        control.dismissSearch()
        isChatPresented = true
        if !draft.isEmpty {
            chat.draft = draft
        }
        Task {
            await chat.refresh()
            if send { chat.send() }
        }
    }

    private func openChatMoment(_ momentID: String) {
        isChatPresented = false
        openSearchHit(
            RecallSearchHit(
                momentId: momentID,
                sessionId: "",
                capturedAtMs: 0,
                source: "chat",
                text: "",
                score: 1
            )
        )
    }
}

private struct PermissionPanel: View {
    @ObservedObject var coordinator: SystemPermissionCoordinator
    @ObservedObject private var hotKeys = RecallHotKeyStore.shared

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Rectangle()
                            .fill(RecallPalette.ray)
                            .frame(width: 18, height: 2)
                        Text("LOCAL ONLY / AFTERRAY")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                    }
                    .foregroundStyle(RecallPalette.ray)
                    Text(coordinator.recordsAudio
                         ? "Three local permissions are required"
                         : "Two local permissions are required")
                        .font(.title2.weight(.semibold))
                    Text(coordinator.recordsAudio
                         ? "AfterRay starts recording automatically as soon as macOS grants all three. Nothing is uploaded."
                         : "Audio recording is off, so the microphone is optional. Screen and Accessibility are still required.")
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

                Text("After changing a permission, press \(hotKeys.hotKey.displayString) to return to AfterRay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if coordinator.isRequesting {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for macOS approval…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Check permissions") { coordinator.refresh() }
                            .buttonStyle(.borderedProminent)
                            .tint(RecallPalette.ray)
                    }
                }
            }
            .padding(28)
            .frame(width: 500)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        }
    }

    private func permissionRow(_ permission: RequiredPermission) -> some View {
        let granted = isGranted(permission)
        return HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .frame(width: 22)
                .foregroundStyle(granted ? Color.green : Color.red)
            Text(permission.title)
                .font(.callout.weight(.medium))
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings") {
                    Task {
                        await coordinator.requestAgain(permission)
                        guard !isGranted(permission) else { return }
                        RecallOverlayController.shared.hide(returnFocus: false)
                        PermissionGuideController.shared.showAfterOpeningSettings(for: permission)
                        coordinator.openSettings(for: permission)
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
}

private struct AfterRaySettingsOverlay: View {
    @ObservedObject var model: AfterRaySettingsModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            AfterRaySettingsView(model: model, onClose: onClose)
                .recallGlass(in: .rounded(14))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// One line for both ways of asking the vault a question. It stays one line in
/// either mode — the chat panel is where an answer goes, and it opens on send
/// or on the chat button, never merely because you pressed Tab.
private struct ImmersiveQueryBar: View {
    @ObservedObject var model: AfterRayControlModel
    @Binding var mode: ImmersiveQueryMode
    let onSubmit: () -> Void
    let onOpenChat: () -> Void
    let onStepResult: (Int) -> Void
    let onClose: () -> Void
    @FocusState private var isInputFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleMode) {
                Label(mode.title, systemImage: mode.symbol)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(mode == .ask ? RecallPalette.ray : .white.opacity(0.76))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(mode.toggleHelp) (Tab)")
            .accessibilityLabel("Input mode")
            .accessibilityValue(mode.title)
            .accessibilityHint(mode.toggleHelp)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)

            HStack(spacing: 8) {
                TextField(mode.placeholder, text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .focused($isInputFocused)
                    .onSubmit(onSubmit)
                    .onKeyPress(keys: [.tab], phases: .down) { _ in
                        toggleMode()
                        return .handled
                    }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.searchQuery.isEmpty {
                    Button(action: clearInput) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
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
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Open chat")
            .accessibilityLabel("Open chat")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Close AfterRay")
        }
        .padding(.horizontal, 14)
        .frame(height: RecallGeometry.overlayChromeButtonSize)
        .recallGlass(in: .capsule)
    }

    private func toggleMode() {
        mode.toggle()
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
                stepButton(symbol: "chevron.left", help: "Older match", delta: 1)
                    .disabled(session.selectedIndex >= session.frames.count - 1)
                stepButton(symbol: "chevron.right", help: "Newer match", delta: -1)
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
            Button("Retry", action: onRetry)
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
