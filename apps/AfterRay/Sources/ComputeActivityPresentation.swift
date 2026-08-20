import AfterRayRecall
import AppKit
import SwiftUI

/// The local-computation dashboard as a real window.
///
/// Deliberately not an overlay inside the recall overlay. That arrangement put a
/// panel above a full-screen surface which is itself a panel: Esc dismissed the
/// wrong thing, the dashboard could not be read beside the app that was making
/// the machine slow, and answering "what is my Mac doing" forced the whole
/// recall surface open. `show()` dismisses the recall overlay first so the
/// window is not trapped under a status-bar panel. A window sits next to
/// anything, and macOS already knows how to close, move and remember one.
///
/// Two entry points open it — the overlay's chrome cluster and the menu bar —
/// because menu-bar space is scarce and that icon is often hidden behind the
/// notch or another app's items.
@MainActor
final class ComputeActivityWindowController: NSObject, NSWindowDelegate {
    static let shared = ComputeActivityWindowController()

    private var window: NSWindow?

    var model: ComputeActivityModel { AfterRayServices.shared.compute }

    func occupiesActivation(excluding closing: NSWindow?) -> Bool {
        guard let window, window !== closing else { return false }
        return window.isVisible || window.isMiniaturized
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        RecallOverlayController.shared.dismissForStandardWindow()
        if let window {
            // Checked before ordering front, which would make it visible and
            // leave a reopened window never polling.
            let wasHidden = !window.isVisible
            AfterRayStandardWindowPresence.activate()
            window.makeKeyAndOrderFront(nil)
            if wasHidden { model.startWatching() }
            ensureDaemon()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AfterRayLocalization.shared.copy.compute.windowTitle
        window.minSize = NSSize(width: 380, height: 420)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.018, green: 0.016, blue: 0.020, alpha: 1)
        window.contentView = NSHostingView(
            rootView: ComputeActivityPanel(model: AfterRayServices.shared.compute)
        )
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.compute-window")
        self.window = window

        AfterRayStandardWindowPresence.activate()
        window.makeKeyAndOrderFront(nil)
        model.startWatching()
        ensureDaemon()
    }

    func close() {
        window?.close()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    /// The retained window can outlive a daemon restart, and the panel's first
    /// poll would then report a connection refusal instead of the machine.
    private func ensureDaemon() {
        Task { @MainActor in
            _ = try? await DaemonSupervisor.shared.startIfNeeded()
            await model.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // The window is ordered out, not torn down, so the panel's own
        // `onDisappear` never fires. Stopping the poll is this controller's job.
        model.stopWatching()
        AfterRayStandardWindowPresence.resignIfLast(
            closing: notification.object as? NSWindow
        )
    }
}
