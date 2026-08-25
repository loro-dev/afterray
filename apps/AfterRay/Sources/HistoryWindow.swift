import AfterRayRecall
import AppKit
import SwiftUI

/// The services the overlay, history window, and chat window share. Every
/// face must observe the same store and chat model — a popped-out panel
/// showing different data from the overlay would be worse than no window.
///
/// Created lazily by whichever face mounts first; the root view adopts these
/// instead of building private copies.
@MainActor
final class AfterRayServices {
    static let shared = AfterRayServices()

    let daemon: UnixSocketDaemonClient
    let images: RecallImageRepository
    let store: RecallStore
    let control: AfterRayControlModel
    let chat: AfterRayChatModel
    let audioPlayer: ArtifactAudioPlayer
    /// Shared, because the overlay button, the menu bar and the panel itself
    /// must agree about what is running. Three pollers would also mean three
    /// times the sampling the panel exists to report on.
    let compute: ComputeActivityModel

    private init() {
        let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        let repository = RecallImageRepository(daemon: daemon)
        self.daemon = daemon
        images = repository
        store = RecallStore(daemon: daemon)
        control = AfterRayControlModel(daemon: daemon)
        chat = AfterRayChatModel(daemon: daemon)
        audioPlayer = ArtifactAudioPlayer(
            repository: RecallAudioRepository(daemon: daemon)
        )
        compute = ComputeActivityModel(daemon: daemon)
    }
}

/// Dock / Cmd-Tab presence for the standard pop-out windows (History, Chat,
/// Settings, Local Computation).
/// The app is menu-bar-only (`.accessory`) unless at least one of them is
/// still visible or miniaturized. Closing History must not hide Chat from
/// the app switcher, and vice versa.
@MainActor
enum AfterRayStandardWindowPresence {
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func resignIfLast(closing: NSWindow?) {
        if HistoryWindowController.shared.occupiesActivation(excluding: closing) { return }
        if ChatWindowController.shared.occupiesActivation(excluding: closing) { return }
        if ComputeActivityWindowController.shared.occupiesActivation(excluding: closing) { return }
        if AfterRaySettingsController.shared.occupiesActivation(excluding: closing) { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The history panel as a real window: normal level, normal Mission
/// Control/Cmd-Tab behaviour, survives the overlay closing. This exists for
/// cross-referencing — reading past summaries beside another app is
/// impossible when the panel lives only inside a full-screen overlay.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func occupiesActivation(excluding closing: NSWindow?) -> Bool {
        guard let window, window !== closing else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func show() {
        RecallOverlayController.shared.dismissForStandardWindow()
        if let window {
            AfterRayStandardWindowPresence.activate()
            window.makeKeyAndOrderFront(nil)
            refreshSummary()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AfterRayLocalization.shared.copy.menu.historyWindow
        window.minSize = NSSize(width: 360, height: 320)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.045, green: 0.04, blue: 0.05, alpha: 1)
        window.contentView = NSHostingView(rootView: HistoryWindowRoot())
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.history-window")
        self.window = window

        // A visible standard window deserves standard app behaviour: a Dock
        // icon and a Cmd-Tab entry while it is open. The app returns to
        // menu-bar-only when the last such window closes.
        AfterRayStandardWindowPresence.activate()
        window.makeKeyAndOrderFront(nil)
        refreshSummary()
    }

    /// The retained window can outlive a daemon restart or a lock-screen
    /// sensitive-state purge. Refresh on every show, including window reuse;
    /// otherwise one transient connection refusal leaves the placeholder
    /// document mounted forever.
    private func refreshSummary() {
        Task { @MainActor in
            do {
                _ = try await DaemonSupervisor.shared.startIfNeeded()
                await AfterRayServices.shared.store.loadDaySummary(
                    dayMs: Int64(Date.now.timeIntervalSince1970 * 1_000),
                    force: true
                )
            } catch {
                AfterRayServices.shared.store.reportFailure(error.localizedDescription)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        AfterRayStandardWindowPresence.resignIfLast(
            closing: notification.object as? NSWindow
        )
    }
}

private struct HistoryWindowRoot: View {
    @ObservedObject private var store = AfterRayServices.shared.store

    var body: some View {
        DaySummaryPanel(
            style: .window,
            summaries: store.summaryHistory.isEmpty ? [store.daySummary] : store.summaryHistory,
            playheadMs: store.playheadMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            hasMore: store.summaryHistoryHasMore,
            totalDays: store.summaryHistoryTotalDays,
            isLoadingMore: store.isLoadingSummaryHistory,
            followPulse: 0,
            onSelectSlot: { slot in
                RecallOverlayController.shared.show(navigatingTo: slot)
            },
            onLoadMore: {
                Task { await AfterRayServices.shared.store.loadOlderSummaryHistory() }
            }
        )
        .preferredColorScheme(.dark)
    }
}
