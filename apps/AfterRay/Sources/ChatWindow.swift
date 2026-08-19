import AfterRayRecall
import AppKit
import SwiftUI

/// Chat as a real window: normal level, Dock / Cmd-Tab while open, and it
/// survives the full-screen overlay closing. The stream lives on
/// `AfterRayServices.shared.chat`, so hiding the overlay or closing this
/// window must not call `stop()`.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    static let shared = ChatWindowController()
    static let minimumExpandedConversationWidth: CGFloat = 560
    static let sidebarAutoCollapseWidth =
        ChatSidebarState.expandedWidth + minimumExpandedConversationWidth

    private var window: NSWindow?
    private var usesCompactLayout: Bool?
    private var sidebarCollapsedAutomatically = false
    let sidebarState = ChatSidebarState()

    func occupiesActivation(excluding closing: NSWindow?) -> Bool {
        guard let window, window !== closing else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func show(
        draft: String = "",
        send: Bool = false,
        startsNewConversation: Bool = false
    ) {
        let chat = AfterRayServices.shared.chat
        if startsNewConversation {
            chat.startNew(draft: draft)
        } else if !draft.isEmpty {
            chat.draft = draft
        }
        if let window {
            AfterRayStandardWindowPresence.activate()
            window.makeKeyAndOrderFront(nil)
            updateResponsiveLayout(for: window)
            refreshThenMaybeSend(send)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AfterRayLocalization.shared.copy.menu.chatWindow
        let minSize = NSSize(width: 720, height: 480)
        window.minSize = minSize
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Standard unified chrome keeps the controls in the traffic-light row
        // without the deliberately reduced margins of `.unifiedCompact`.
        window.toolbarStyle = .unified
        window.toolbar = makeToolbar()
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = ChatHostingView(rootView: ChatWindowRoot(sidebarState: sidebarState))
        // Default options also report intrinsic/max size, which pins the
        // window to SwiftUI's ideal size so edge-drag snaps back. Min only:
        // the view tracks contentView.bounds above that floor.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.chat-window")
        self.window = window

        AfterRayStandardWindowPresence.activate()
        window.makeKeyAndOrderFront(nil)
        updateResponsiveLayout(for: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.updateResponsiveLayout(for: window)
        }
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

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateResponsiveLayout(for: window)
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: .afterRayChat)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .chatSidebarToggle,
            .space,
            .space,
            .flexibleSpace,
            .chatTitle,
            .flexibleSpace,
            .chatNewConversation,
            .chatMore,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .chatSidebarToggle:
            let item = toolbarButton(
                identifier: itemIdentifier,
                label: sidebarToggleLabel,
                symbol: "sidebar.left",
                action: #selector(toggleSidebar(_:))
            )
            item.isNavigational = true
            return item
        case .chatTitle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Conversation title"
            item.paletteLabel = item.label
            item.view = NSHostingView(
                rootView: ChatToolbarTitleView(model: AfterRayServices.shared.chat)
            )
            item.visibilityPriority = .high
            return item
        case .chatNewConversation:
            return toolbarButton(
                identifier: itemIdentifier,
                label: "New conversation",
                symbol: "plus",
                action: #selector(startNewConversation(_:))
            )
        case .chatMore:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "More"
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
            item.menu = makeMoreMenu()
            item.showsIndicator = false
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarState.isCollapsed.toggle()
        sidebarCollapsedAutomatically = false
        let item = (sender as? NSToolbarItem) ?? window?.toolbar?.items.first {
            $0.itemIdentifier == .chatSidebarToggle
        }
        updateSidebarToggleItem(item)
        if let toolbar = item?.toolbar ?? window?.toolbar {
            updateToolbarAlignmentItems(in: toolbar)
        }
    }

    func updateResponsiveLayout(for window: NSWindow) {
        let isCompact = window.contentLayoutRect.width < Self.sidebarAutoCollapseWidth

        if usesCompactLayout != isCompact {
            usesCompactLayout = isCompact
            if isCompact, !sidebarState.isCollapsed {
                sidebarState.isCollapsed = true
                sidebarCollapsedAutomatically = true
            } else if !isCompact, sidebarCollapsedAutomatically {
                sidebarState.isCollapsed = false
                sidebarCollapsedAutomatically = false
            }
            updateSidebarToggleItem(
                window.toolbar?.items.first { $0.itemIdentifier == .chatSidebarToggle }
            )
        }

        if let toolbar = window.toolbar {
            updateToolbarAlignmentItems(in: toolbar)
        }
    }

    private func updateSidebarToggleItem(_ item: NSToolbarItem?) {
        guard let item else { return }
        item.label = sidebarToggleLabel
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: item.label
        )
    }

    private func updateToolbarAlignmentItems(in toolbar: NSToolbar) {
        let alignmentIndices = toolbar.items.indices.filter {
            toolbar.items[$0].itemIdentifier == .space
        }
        let desiredCount = sidebarState.isCollapsed ? 0 : 2
        guard alignmentIndices.count != desiredCount else { return }

        for index in alignmentIndices.reversed() {
            toolbar.removeItem(at: index)
        }
        guard desiredCount > 0,
              let sidebarIndex = toolbar.items.firstIndex(where: {
                  $0.itemIdentifier == .chatSidebarToggle
              })
        else { return }
        for offset in 0..<desiredCount {
            toolbar.insertItem(withItemIdentifier: .space, at: sidebarIndex + 1 + offset)
        }
    }

    @objc func startNewConversation(_ sender: Any?) {
        AfterRayServices.shared.chat.startNew()
    }

    @objc func copyConversationMarkdown(_ sender: Any?) {
        let chat = AfterRayServices.shared.chat
        let markdown = ChatConversationExport.markdown(
            title: chat.selectedTitle,
            bubbles: chat.bubbles
        )
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copyConversationMarkdown(_:)) else { return true }
        return AfterRayServices.shared.chat.bubbles.contains { bubble in
            switch bubble.role {
            case .compaction:
                return !bubble.text.isEmpty
            case .user, .assistant:
                return !bubble.text.isEmpty || !bubble.parts.isEmpty
            }
        }
    }

    private var sidebarToggleLabel: String {
        sidebarState.isCollapsed ? "Show sidebar" : "Hide sidebar"
    }

    private func toolbarButton(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.autovalidates = false
        item.visibilityPriority = .high
        return item
    }

    private func makeMoreMenu() -> NSMenu {
        let strings = AfterRayLocalization.shared.copy
        let menu = NSMenu(title: strings.chat.more)
        let copy = NSMenuItem(
            title: strings.chat.copyEntire,
            action: #selector(copyConversationMarkdown(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: copy.title)
        menu.addItem(copy)
        return menu
    }
}

private struct ChatWindowRoot: View {
    @ObservedObject private var chat = AfterRayServices.shared.chat
    private let images = AfterRayServices.shared.images
    let sidebarState: ChatSidebarState

    var body: some View {
        ZStack {
            RecallBehindWindowFill()
                .ignoresSafeArea()
            AfterRayChatView(
                model: chat,
                onClose: { ChatWindowController.shared.close() },
                onOpenMoment: { momentID in
                    RecallOverlayController.shared.show(navigatingToMoment: momentID)
                },
                thumbnailLoader: { momentID in
                    try await images.thumbnail(momentID: momentID).bytes
                },
                previewLoader: { momentID in
                    let moment = try await images.moment(id: momentID)
                    return try await images.chatPreviewBytes(for: moment)
                },
                momentLoader: { momentID in
                    try await images.moment(id: momentID)
                },
                fillsAvailableSpace: true,
                showsHeader: false,
                sidebarState: sidebarState
            )
        }
        .preferredColorScheme(.dark)
    }
}

extension NSToolbar.Identifier {
    static let afterRayChat = NSToolbar.Identifier("dev.afterray.chat-toolbar")
}

extension NSToolbarItem.Identifier {
    static let chatSidebarToggle = NSToolbarItem.Identifier("dev.afterray.chat.sidebar-toggle")
    static let chatTitle = NSToolbarItem.Identifier("dev.afterray.chat.title")
    static let chatNewConversation = NSToolbarItem.Identifier("dev.afterray.chat.new-conversation")
    static let chatMore = NSToolbarItem.Identifier("dev.afterray.chat.more")
}
