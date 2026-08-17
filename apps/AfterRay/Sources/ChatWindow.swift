import AfterRayRecall
import AppKit
import SwiftUI

/// Chat as a real window: normal level, Dock / Cmd-Tab while open, and it
/// survives the full-screen overlay closing. The stream lives on
/// `AfterRayServices.shared.chat`, so hiding the overlay or closing this
/// window must not call `stop()`.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    static let shared = ChatWindowController()

    private var window: NSWindow?

    func occupiesActivation(excluding closing: NSWindow?) -> Bool {
        guard let window, window !== closing else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func show(draft: String = "", send: Bool = false) {
        if !draft.isEmpty {
            AfterRayServices.shared.chat.draft = draft
        }
        if let window {
            AfterRayStandardWindowPresence.activate()
            window.makeKeyAndOrderFront(nil)
            refreshThenMaybeSend(send)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AfterRay Chat"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.045, green: 0.04, blue: 0.05, alpha: 1)
        window.contentView = NSHostingView(rootView: ChatWindowRoot())
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.chat-window")
        self.window = window

        AfterRayStandardWindowPresence.activate()
        window.makeKeyAndOrderFront(nil)
        refreshThenMaybeSend(send)
    }

    /// Close the chrome only. Do not abort an in-flight turn — the daemon
    /// treats a dropped stream as "read later", and the model outlives us.
    func close() {
        window?.close()
    }

    /// The retained window can outlive a daemon restart. Refresh on every
    /// show, including reuse, so a first-open connection refusal does not
    /// leave an empty sidebar forever.
    private func refreshThenMaybeSend(_ send: Bool) {
        Task { @MainActor in
            do {
                _ = try await DaemonSupervisor.shared.startIfNeeded()
            } catch {
                // `refresh()` still runs so the panel can show the disconnect note.
            }
            await AfterRayServices.shared.chat.refresh()
            if send { AfterRayServices.shared.chat.send() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        AfterRayStandardWindowPresence.resignIfLast(
            closing: notification.object as? NSWindow
        )
    }
}

private struct ChatWindowRoot: View {
    @ObservedObject private var chat = AfterRayServices.shared.chat
    private let images = AfterRayServices.shared.images

    var body: some View {
        AfterRayChatView(
            model: chat,
            onClose: { ChatWindowController.shared.close() },
            onOpenMoment: { momentID in
                RecallOverlayController.shared.show(navigatingToMoment: momentID)
            },
            thumbnailLoader: { momentID in
                try await images.thumbnail(momentID: momentID).bytes
            },
            fillsAvailableSpace: true
        )
        .preferredColorScheme(.dark)
    }
}
