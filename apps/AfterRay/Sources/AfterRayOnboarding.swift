import AfterRayRecall
import AppKit
import SwiftUI

/// Borderless, but still a real key window: the shortcut recorder needs the
/// keyboard, and an agent app has no other window to hand it over from.
private final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_: Any?) {
        OnboardingController.shared.finish()
    }
}

/// First launch, once. AfterRay has no dock icon and no window, so without
/// this the app is invisible and the shortcut is a secret.
@MainActor
final class OnboardingController: ObservableObject {
    static let shared = OnboardingController()

    private static let completedKey = "dev.afterray.onboarding.completed.v1"

    private let defaults: UserDefaults
    private var model: AfterRayOnboardingModel
    private var panel: OnboardingPanel?
    private var practiceMonitor: Any?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isFinished: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isFinished = !CommandLine.arguments.contains("--onboarding")
            && defaults.bool(forKey: Self.completedKey)
        model = Self.makeModel()
    }

    private static func makeModel() -> AfterRayOnboardingModel {
        let exclusions = OnboardingExclusions()
        return AfterRayOnboardingModel(
            hotKeys: .shared,
            privacyActions: AfterRayOnboardingPrivacyActions(
                excludedApps: { exclusions.bundleIds },
                excludedDomains: { exclusions.domains },
                protectedApps: { exclusions.protectedBundleIds },
                refresh: { await exclusions.load() },
                addApp: { await exclusions.pickApp() },
                removeApp: { bundleID in await exclusions.removeApp(bundleID) },
                addDomain: { typed in await exclusions.addDomain(typed) },
                removeDomain: { domain in await exclusions.removeDomain(domain) },
                displayName: { OnboardingExclusions.displayName(for: $0) },
                iconPath: { OnboardingExclusions.iconPath(for: $0) },
                message: { exclusions.message }
            ),
            cliActions: AfterRayOnboardingCliActions(
                status: { AfterRayCliInstall.statusSummary },
                isInstalled: { AfterRayCliInstall.isInstalled },
                install: {
                    _ = try AfterRayCliInstall.install()
                },
                pathExportLine: { AfterRayCliInstall.pathExportLine() }
            ),
            modelActions: AfterRayOnboardingModelActions(
                status: {
                    _ = try await DaemonSupervisor.shared.startIfNeeded()
                    return try await UnixSocketDaemonClient(
                        socketPath: DaemonSupervisor.shared.socketPath
                    ).modelLibrary()
                },
                download: { packIDs in
                    _ = try await DaemonSupervisor.shared.startIfNeeded()
                    return try await UnixSocketDaemonClient(
                        socketPath: DaemonSupervisor.shared.socketPath
                    ).startModelDownloads(packIDs: packIDs)
                }
            )
        )
    }

    var isVisible: Bool { panel?.isVisible == true }

    func showIfNeeded() {
        guard !isFinished, panel == nil else { return }
        show()
    }

    /// Development-only entry point wired into the menu bar. It leaves the
    /// completion preference intact, so quitting halfway through a replay
    /// cannot turn the next normal launch back into a first launch.
    func replay() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        AfterRaySettingsController.shared.hide()
        RecallOverlayController.shared.hide(returnFocus: false)
        model = Self.makeModel()
        isFinished = false
        show()
    }

    /// Routes the global shortcut into the lesson instead of the overlay while
    /// the window is up. Returns true when the press was consumed.
    func handleHotKey() -> Bool {
        guard isVisible else { return false }
        return model.registerPractice()
    }

    func finish() {
        guard !isFinished || isVisible else { return }
        isFinished = true
        model.stopObservingModelDownloads()
        defaults.set(true, forKey: Self.completedKey)
        dismissPanel()
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        RecallOverlayController.shared.show()
    }

    /// Lets the permission flow hold back its system prompts until the welcome
    /// window is out of the way. Returns immediately on later launches.
    func waitUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func show() {
        let hosting = NSHostingView(
            rootView: AfterRayOnboardingView(model: model) { [weak self] in
                self?.finish()
            }
        )
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel

        let screen = targetScreen
        let resting = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2 + 40
        )
        panel.setFrame(NSRect(origin: NSPoint(x: resting.x, y: resting.y - 14), size: size), display: true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        beginPracticeMonitoring()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: resting, size: size), display: true)
        }
    }

    private func dismissPanel() {
        endPracticeMonitoring()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func beginPracticeMonitoring() {
        guard practiceMonitor == nil else { return }
        practiceMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return event }
            model.updatePracticeModifiers(RecallHotKey.Modifiers(event.modifierFlags))
            switch event.type {
            case .keyDown:
                if !event.isARepeat {
                    model.updatePracticeKey(keyCode: event.keyCode, isPressed: true)
                }
            case .keyUp:
                model.updatePracticeKey(keyCode: event.keyCode, isPressed: false)
            default:
                break
            }
            return event
        }
    }

    private func endPracticeMonitoring() {
        guard let practiceMonitor else { return }
        NSEvent.removeMonitor(practiceMonitor)
        self.practiceMonitor = nil
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
