import AppKit
import SwiftUI

private enum ChatMetrics {
    static let panelWidth: CGFloat = 960
    static let panelHeight: CGFloat = 660
    static let panelRadius: CGFloat = 14
    static let sidebarWidth: CGFloat = 228
    static let bubbleRadius: CGFloat = 12
    static let gutter: CGFloat = 20
    static let titlebarHeight: CGFloat = 32
    /// Close / miniaturize / zoom sit in the first ~72pt; leave a gap after.
    static let trafficLightClearance: CGFloat = 80
    static let conversationRowHeight: CGFloat = 32
    static let bottomAnchorID = "afterray-chat-bottom-anchor"
}

enum ChatPalette {
    static let accent = RecallPalette.ray
    static let coral = Color(red: 1.0, green: 0.38, blue: 0.28)
    static let panel = Color(red: 0.055, green: 0.052, blue: 0.060)
    static let sidebar = Color.black.opacity(0.24)
    static let label = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.60)
    static let tertiary = Color.white.opacity(0.40)
    static let card = Color.white.opacity(0.042)
    static let cardStroke = Color.white.opacity(0.070)
    static let separator = Color.white.opacity(0.055)
    static let userFill = Color(hue: 0.02, saturation: 0.16, brightness: 0.30)
    static let userStroke = Color.white.opacity(0.08)
    static let deleteHover = Color(red: 0.78, green: 0.46, blue: 0.42)
    static let assistantFill = Color.white.opacity(0.045)
    static let codeFill = Color.black.opacity(0.46)
}

public struct AfterRayChatView<Model: AfterRayChatModeling>: View {
    @ObservedObject var model: Model
    var onClose: () -> Void
    var onOpenMoment: ((String) -> Void)?
    var thumbnailLoader: RecallThumbnailLoader?
    var previewLoader: RecallChatPreviewLoader?
    var momentLoader: RecallMomentLoader?
    var fillsAvailableSpace: Bool
    var occupiesWindowTitlebar: Bool
    @State private var autoScrollState = ChatAutoScrollState()
    @State private var scrollToLatestRequest: UInt64 = 0
    @State private var sidebarCollapsed = false
    @State private var conversationQuery = ""
    @State private var modelPickerOpen = false
    @State private var moreMenuOpen = false
    @State private var conversationCopied = false
    @State private var titlebarInset = ChatMetrics.titlebarHeight

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        onOpenMoment: ((String) -> Void)? = nil,
        thumbnailLoader: RecallThumbnailLoader? = nil,
        previewLoader: RecallChatPreviewLoader? = nil,
        momentLoader: RecallMomentLoader? = nil,
        fillsAvailableSpace: Bool = false,
        occupiesWindowTitlebar: Bool = false
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenMoment = onOpenMoment
        self.thumbnailLoader = thumbnailLoader
        self.previewLoader = previewLoader
        self.momentLoader = momentLoader
        self.fillsAvailableSpace = fillsAvailableSpace
        self.occupiesWindowTitlebar = occupiesWindowTitlebar
    }

    public var body: some View {
        ZStack {
            if occupiesWindowTitlebar {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { updateTitlebarInset(geo.safeAreaInsets.top) }
                        .onChange(of: geo.safeAreaInsets.top) { _, top in
                            updateTitlebarInset(top)
                        }
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    sidebar
                }
                thread
            }
            .modifier(ChatTitlebarSafeArea(enabled: occupiesWindowTitlebar))
        }
        .frame(
            minWidth: fillsAvailableSpace ? 720 : ChatMetrics.panelWidth,
            maxWidth: fillsAvailableSpace ? .infinity : ChatMetrics.panelWidth,
            minHeight: fillsAvailableSpace ? 480 : ChatMetrics.panelHeight,
            maxHeight: fillsAvailableSpace ? .infinity : ChatMetrics.panelHeight
        )
        .background {
            if fillsAvailableSpace {
                Color.white.opacity(0.04)
            } else {
                ChatPalette.panel
            }
        }
        .preferredColorScheme(.dark)
        .modifier(ChatSurfaceChrome(isPanel: !fillsAvailableSpace))
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "afterray", url.host == "moment" {
                let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !id.isEmpty {
                    onOpenMoment?(id)
                    return .handled
                }
            }
            return .systemAction
        })
        .task { await model.refresh() }
        .animation(.easeOut(duration: 0.16), value: sidebarCollapsed)
        .onChange(of: model.selectedID) { _, _ in
            conversationCopied = false
        }
        .task(id: conversationCopied) {
            guard conversationCopied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            conversationCopied = false
        }
    }

    private var chromeHeight: CGFloat {
        occupiesWindowTitlebar ? titlebarInset : ChatMetrics.titlebarHeight
    }

    private func updateTitlebarInset(_ top: CGFloat) {
        let next = max(top, ChatMetrics.titlebarHeight)
        if abs(next - titlebarInset) > 0.5 {
            titlebarInset = next
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarTitlebar

            if !model.conversations.isEmpty {
                conversationSearchField
            }

            if model.isLoadingList, model.conversations.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(ChatPalette.accent)
                    Text("Loading…")
                        .font(.system(size: 12))
                        .foregroundStyle(ChatPalette.tertiary)
                }
                .padding(.horizontal, 6)
            } else if model.conversations.isEmpty {
                Text("Past chats will show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            } else if conversationDays.isEmpty {
                Text("No chats match.")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatPalette.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversationDays) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ChatPalette.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                                ForEach(group.conversations) { conversation in
                                    ChatConversationRow(
                                        conversation: conversation,
                                        isSelected: conversation.id == model.selectedID,
                                        onSelect: { Task { await model.select(conversation.id) } },
                                        onDelete: { Task { await model.deleteConversation(conversation.id) } }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, occupiesWindowTitlebar ? 0 : 8)
        .padding(.bottom, 12)
        .frame(width: ChatMetrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .trailing) {
            Rectangle().fill(ChatPalette.separator).frame(width: 1)
        }
    }

    private var sidebarTitlebar: some View {
        HStack(spacing: 0) {
            if occupiesWindowTitlebar {
                Color.clear
                    .frame(width: max(0, ChatMetrics.trafficLightClearance - 10))
            }
            ChatIconButton(
                symbol: "sidebar.left",
                help: "Hide sidebar",
                action: { sidebarCollapsed = true }
            )
            Spacer(minLength: 0)
        }
        .frame(height: chromeHeight)
    }

    /// Filter then group — each is one pass / one sort, not per row.
    private var conversationDays: [ChatDayGroup] {
        ChatConversationGrouping.days(
            ChatConversationGrouping.matching(model.conversations, query: conversationQuery)
        )
    }

    private var conversationSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatPalette.tertiary)
            TextField("Search chats", text: $conversationQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(ChatPalette.label)
            if !conversationQuery.isEmpty {
                Button {
                    conversationQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatPalette.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var thread: some View {
        VStack(spacing: 0) {
            header
            messageList
            statusStrip
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        ZStack {
            Text(model.selectedTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatPalette.label)
                .lineLimit(1)
                .padding(.horizontal, 120)
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                if occupiesWindowTitlebar && sidebarCollapsed {
                    Color.clear
                        .frame(width: max(0, ChatMetrics.trafficLightClearance - 14))
                }
                if sidebarCollapsed {
                    ChatIconButton(
                        symbol: "sidebar.left",
                        help: "Show sidebar",
                        action: { sidebarCollapsed = false }
                    )
                }
                if model.isLoadingHistory {
                    ProgressView().controlSize(.small).tint(ChatPalette.accent)
                }
                Spacer(minLength: 8)
                ChatIconButton(symbol: "plus", help: "New conversation", action: model.startNew)
                ChatIconButton(symbol: "ellipsis", help: "More", action: { moreMenuOpen.toggle() })
                    .popover(isPresented: $moreMenuOpen, arrowEdge: .bottom) {
                        moreMenu
                    }
                if !fillsAvailableSpace {
                    ChatIconButton(symbol: "xmark", help: "Close chat", action: onClose)
                }
            }
        }
        .padding(.horizontal, occupiesWindowTitlebar ? 10 : 14)
        .frame(height: chromeHeight)
        .padding(.top, occupiesWindowTitlebar ? 0 : 8)
        .padding(.bottom, occupiesWindowTitlebar ? 0 : 4)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    // Eager on purpose. LazyVStack estimates unloaded cells at
                    // ~0 height; markdown, citations and disclosure folds then
                    // resize the document under the viewport and the user
                    // lands in empty space. Chat threads stay short enough
                    // that mounting every bubble is cheaper than virtualizing
                    // variable-height rows.
                    VStack(alignment: .leading, spacing: 14) {
                        if model.bubbles.isEmpty, !model.isSending {
                            emptyState
                                .padding(.top, 48)
                        }
                        ForEach(model.bubbles) { bubble in
                            messageRow(bubble)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(ChatMetrics.bottomAnchorID)
                    }
                    .background(
                        ChatScrollObserver(onChange: handleScrollMetrics)
                    )
                    .padding(.horizontal, ChatMetrics.gutter)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // macOS 14: pin growing content only while a turn is streaming
                // and the user still wants latest. Idle size changes must not
                // consult a bottom anchor — that is the old re-stick trap.
                .defaultScrollAnchor(pinsToBottom ? .bottom : nil)
                .background(ScrollFenceView())
                .task(id: scrollToLatestRequest) {
                    guard scrollToLatestRequest > 0 else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(ChatMetrics.bottomAnchorID, anchor: .bottom)
                }

                if autoScrollState.shouldShowLatestButton {
                    ChatLatestButton(action: followLatest)
                        .padding(14)
                        .transition(.opacity)
                }
            }
            .onAppear {
                if !model.isLoadingHistory, !model.bubbles.isEmpty {
                    applyScrollAction(autoScrollState.noteConversationContentReady())
                }
            }
            .onChange(of: model.bubbles.last?.text) { _, _ in
                requestLatestScrollIfFollowing()
            }
            .onChange(of: model.bubbles.count) { _, count in
                if count > 0, !model.isSending {
                    applyScrollAction(autoScrollState.noteConversationContentReady())
                }
            }
            .onChange(of: model.isLoadingHistory) { _, loading in
                if !loading {
                    applyScrollAction(autoScrollState.noteConversationContentReady())
                }
            }
            .onChange(of: model.isSending) { _, isSending in
                applyScrollAction(autoScrollState.noteSendingChanged(isSending))
            }
            .onChange(of: model.selectedID) { _, _ in
                autoScrollState.resetForConversation()
                requestLatestScroll()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pinsToBottom: Bool {
        autoScrollState.isFollowingLatest && model.isSending
    }

    @ViewBuilder
    private func messageRow(_ bubble: ChatBubble) -> some View {
        if bubble.role == .compaction {
            ChatCompactionRule(text: bubble.text)
                .id(bubble.id)
        } else {
            ChatBubbleView(
                bubble: bubble,
                thumbnailLoader: thumbnailLoader,
                previewLoader: previewLoader,
                momentLoader: momentLoader,
                onOpenMoment: onOpenMoment
            )
            .id(bubble.id)
        }
    }

    private func handleScrollMetrics(_ metrics: ChatScrollMetrics) {
        applyScrollAction(autoScrollState.decide(metrics: metrics, isSending: model.isSending))
    }

    private func requestLatestScrollIfFollowing() {
        guard autoScrollState.isFollowingLatest, model.isSending else { return }
        requestLatestScroll()
    }

    private func followLatest() {
        autoScrollState.followLatest()
        requestLatestScroll()
    }

    private func applyScrollAction(_ action: ChatScrollAction) {
        if action == .scrollToLatest {
            requestLatestScroll()
        }
    }

    private func requestLatestScroll() {
        scrollToLatestRequest &+= 1
    }

    private var emptyState: some View {
        Text("Ask anything AfterRay has already seen.")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ChatPalette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let message = model.errorMessage ?? model.statusMessage, !message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatPalette.tertiary)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ChatPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ChatMetrics.gutter)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.22))
            .overlay(alignment: .top) {
                Rectangle().fill(ChatPalette.separator).frame(height: 1)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ChatComposerField(text: $model.draft, isEnabled: !model.isSending, onSend: model.send)
                    .frame(height: 36)
                composerAction
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }

            HStack(spacing: 10) {
                modelMenu
                if let usage = model.contextUsage {
                    ChatContextRing(usage: usage)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var composerAction: some View {
        if model.isSending {
            Button(action: model.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(ChatPalette.accent, in: Circle())
            }
            .buttonStyle(ChatPressStyle())
            .help("Stop generating")
        } else {
            Button(action: model.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        ChatPalette.accent.opacity(model.canSend ? 0.95 : 0.38),
                        in: Circle()
                    )
            }
            .buttonStyle(ChatPressStyle())
            .disabled(!model.canSend)
            .help("Send")
        }
    }

    private var modelMenuSections: [(group: String, models: [ChatModelChoice])] {
        var order: [String] = []
        var buckets: [String: [ChatModelChoice]] = [:]
        buckets.reserveCapacity(4)
        for choice in model.chatModels {
            if buckets[choice.group] == nil {
                order.append(choice.group)
            }
            buckets[choice.group, default: []].append(choice)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var modelMenu: some View {
        Button {
            modelPickerOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedChatModelTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ChatPalette.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .recallHoverFill(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(ChatPressStyle())
        .popover(isPresented: $modelPickerOpen, arrowEdge: .top) {
            ChatModelPickerList(
                sections: modelMenuSections,
                selectedID: model.selectedChatModelID,
                onPick: { id in
                    model.selectChatModel(id)
                    modelPickerOpen = false
                }
            )
        }
        .help("Choose a model")
    }

    private var moreMenu: some View {
        Button {
            copyConversationMarkdown()
            moreMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: conversationCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(conversationCopied ? ChatPalette.accent : ChatPalette.secondary)
                    .frame(width: 14)
                Text(conversationCopied ? "Copied" : "Copy Entire Conversation as Markdown")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatPalette.label)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCopyConversation)
        .help("Copy this thread including thinking and tool results")
        .padding(6)
        .frame(minWidth: 280)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("chat-copy-conversation")
    }

    private var canCopyConversation: Bool {
        model.bubbles.contains { bubble in
            switch bubble.role {
            case .compaction:
                return !bubble.text.isEmpty
            case .user, .assistant:
                return !bubble.text.isEmpty || !bubble.parts.isEmpty
            }
        }
    }

    private func copyConversationMarkdown() {
        let markdown = ChatConversationExport.markdown(
            title: model.selectedTitle,
            bubbles: model.bubbles
        )
        guard !markdown.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        conversationCopied = true
    }
}

private struct ChatModelPickerList: View {
    let sections: [(group: String, models: [ChatModelChoice])]
    let selectedID: String?
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.group)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ChatPalette.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                        ForEach(section.models) { choice in
                            Button {
                                onPick(choice.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(choice.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(ChatPalette.label)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if choice.id == selectedID {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(ChatPalette.accent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
        .frame(maxHeight: 280)
        .background(.ultraThinMaterial)
    }
}

/// Overlay chat is a fixed rounded card. Window chat must not clip to that
/// panel — a real `NSWindow` already has a titlebar and resizable edges.
private struct ChatSurfaceChrome: ViewModifier {
    let isPanel: Bool

    func body(content: Content) -> some View {
        if isPanel {
            content
                .clipShape(RoundedRectangle(cornerRadius: ChatMetrics.panelRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ChatMetrics.panelRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                }
        } else {
            content
        }
    }
}

/// Draw custom chrome in the real titlebar instead of sitting under it.
private struct ChatTitlebarSafeArea: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

/// Where the agent stopped being able to see.
///
/// Drawn as a rule across the thread rather than a bubble: it is not something
/// anyone said, and a shorter answer below it needs the explanation to not
/// simply read as the assistant getting worse.
private struct ChatCompactionRule: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            line
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 10.5))
                    // One line, always. A wrapped divider reads as a message.
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(ChatPalette.tertiary)
            .layoutPriority(1)
            line
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(ChatPalette.separator)
            .frame(height: 1)
    }
}

private struct ChatConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isHoveringTrash = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? ChatPalette.label : ChatPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHoveringTrash ? ChatPalette.deleteHover : ChatPalette.tertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            isHoveringTrash ? ChatPalette.deleteHover.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("删除该对话")
                .onHover { isHoveringTrash = $0 }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            .padding(.horizontal, 8)
            .frame(height: ChatMetrics.conversationRowHeight)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(ChatPressStyle())
        .onHover { hovering in
            isHovering = hovering
            if !hovering { isHoveringTrash = false }
        }
        .help(isHoveringTrash ? "删除该对话" : conversation.title)
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.10) }
        return isHovering ? Color.white.opacity(0.05) : .clear
    }
}

private struct ChatContextRing: View {
    let usage: ChatContextUsage
    @State private var isHovering = false
    @State private var showDetails = false

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(isHovering || showDetails ? 0.28 : 0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: usage.fraction)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                Text(usage.percentLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHovering || showDetails ? ChatPalette.label : ChatPalette.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isHovering || showDetails ? Color.white.opacity(0.08) : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context window")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatPalette.tertiary)
                Text(usage.shortLabel.replacingOccurrences(of: " / ", with: "/"))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ChatPalette.label)
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("Used", ChatContextUsage.compact(usage.promptTokens))
                    detailRow("Total", ChatContextUsage.compact(usage.windowTokens))
                }
            }
            .padding(12)
            .frame(minWidth: 176, alignment: .leading)
        }
        .help("Context used: \(usage.shortLabel)")
        .accessibilityLabel("Context window")
        .accessibilityValue("\(usage.percentLabel) used, \(usage.shortLabel)")
        .accessibilityIdentifier("chat-context-ring")
    }

    private var ringColor: Color {
        if usage.isTight {
            return ChatPalette.coral
        }
        return Color.white.opacity(isHovering || showDetails ? 0.92 : 0.72)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(ChatPalette.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ChatPalette.label)
        }
    }
}

private struct ChatBubbleView: View {
    let bubble: ChatBubble
    let thumbnailLoader: RecallThumbnailLoader?
    let previewLoader: RecallChatPreviewLoader?
    let momentLoader: RecallMomentLoader?
    let onOpenMoment: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            if bubble.role == .user { Spacer(minLength: 48) }
            VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
                if !bubble.parts.isEmpty {
                    if bubble.isStreaming {
                        ForEach(bubble.parts) { part in
                            workPart(part)
                        }
                    } else {
                        ChatWorkProcessCard(
                            parts: bubble.parts,
                            elapsedMs: bubble.workElapsedMs,
                            isStreaming: false
                        ) { part in
                            workPart(part)
                        }
                    }
                }
                if shouldShowBody {
                    bubbleBody
                }
            }
            .frame(maxWidth: 560, alignment: bubble.role == .user ? .trailing : .leading)
            if bubble.role == .assistant { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func workPart(_ part: ChatMessagePart) -> some View {
        switch part {
        case .reasoning(let id, _, let text):
            ChatReasoningChip(
                text: text,
                isActive: isActiveReasoning(id),
                progress: isActiveReasoning(id) ? bubble.progress : nil
            )
        case .tool(let tool):
            ChatToolChip(tool: tool)
        }
    }

    /// The thought still arriving — last reasoning part, no answer yet.
    /// Earlier thoughts stay folded so think → tool → think reads as
    /// three stretches, not one chip above the tools.
    private func isActiveReasoning(_ id: String) -> Bool {
        guard bubble.isStreaming, bubble.text.isEmpty,
              case .reasoning(let lastID, _, _) = bubble.parts.last
        else { return false }
        return lastID == id
    }

    private var shouldShowBody: Bool {
        if !bubble.text.isEmpty { return true }
        guard bubble.isStreaming else { return false }
        if case .reasoning = bubble.parts.last, bubble.text.isEmpty {
            return false
        }
        return true
    }

    private var showsTurnMeta: Bool {
        if let rate = bubble.tokensPerSecond, rate > 0 { return true }
        return !bubble.isStreaming && !bubble.text.isEmpty
    }

    @ViewBuilder
    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bubble.role == .user {
                ChatMarkdownView(
                    blocks: bubble.markdownBlocks,
                    thumbnailLoader: thumbnailLoader,
                    previewLoader: previewLoader,
                    momentLoader: momentLoader,
                    onOpenMoment: onOpenMoment
                )
                .textSelection(.enabled)
            } else {
                // The indicator replaces the caret rather than joining it. A
                // blinking caret in front of no text reads as "waiting for you";
                // this reads as "waiting for me".
                if let progress = bubble.progress, bubble.text.isEmpty {
                    ChatWorkingIndicator(progress: progress)
                } else {
                    ChatMarkdownView(
                        blocks: bubble.markdownBlocks,
                        thumbnailLoader: thumbnailLoader,
                        previewLoader: previewLoader,
                        momentLoader: momentLoader,
                        onOpenMoment: onOpenMoment
                    )
                        .textSelection(.enabled)
                    if bubble.isStreaming {
                        ChatStreamCaret()
                    }
                    if bubble.wasAborted {
                        // What is above is real, just not all of what was
                        // coming. Saying so stops a half answer reading as a
                        // confident short one.
                        Text("Stopped — this is as far as it got.")
                            .font(.system(size: 11))
                            .foregroundStyle(ChatPalette.tertiary)
                    }
                    if showsTurnMeta {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            if let rate = bubble.tokensPerSecond {
                                Text(ChatTokenEstimate.rateLabel(rate))
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(ChatPalette.tertiary)
                                    .help("Estimated tokens per second for this turn")
                                    .accessibilityIdentifier("chat-tokens-per-second-\(bubble.id)")
                            }
                            if !bubble.isStreaming, !bubble.text.isEmpty {
                                Button(action: copyOutput) {
                                    Label(
                                        copied ? "Copied" : "Copy",
                                        systemImage: copied ? "checkmark" : "doc.on.doc"
                                    )
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(copied ? ChatPalette.accent : ChatPalette.tertiary)
                                    .padding(.horizontal, 7)
                                    .frame(height: 24)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(copied ? "Agent output copied" : "Copy agent output")
                                .accessibilityIdentifier("chat-copy-output-\(bubble.id)")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous)
                .strokeBorder(bubbleStroke, lineWidth: 1)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bubble.text, forType: .string)
        copied = true
    }

    private var bubbleBackground: Color {
        bubble.role == .user ? ChatPalette.userFill.opacity(0.92) : ChatPalette.assistantFill
    }

    private var bubbleStroke: Color {
        bubble.role == .user ? ChatPalette.userStroke : ChatPalette.cardStroke
    }
}

/// After the answer lands, every thought and tool folds into one row so
/// a long ReAct trace does not sit open above the reply.
private struct ChatWorkProcessCard<PartView: View>: View {
    let parts: [ChatMessagePart]
    let elapsedMs: Int?
    let isStreaming: Bool
    @ViewBuilder var partView: (ChatMessagePart) -> PartView
    @State private var expanded: Bool

    init(
        parts: [ChatMessagePart],
        elapsedMs: Int?,
        isStreaming: Bool,
        @ViewBuilder partView: @escaping (ChatMessagePart) -> PartView
    ) {
        self.parts = parts
        self.elapsedMs = elapsedMs
        self.isStreaming = isStreaming
        self.partView = partView
        _expanded = State(initialValue: isStreaming)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parts) { part in
                    partView(part)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text(ChatWorkSummary.label(
                thoughts: ChatMessagePart.reasoning(in: parts).count,
                lookups: ChatMessagePart.tools(in: parts).count,
                elapsedMs: elapsedMs
            ))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChatPalette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(ChatPalette.tertiary)
        .disclosureGroupStyle(ChatLeadingDisclosureStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { expanded = false }
        }
    }
}

/// One thought, in the place it arrived. Live text stays open; a finished
/// thought folds so the next tool or thought can take the eye.
private struct ChatReasoningChip: View {
    let text: String
    let isActive: Bool
    let progress: ChatProgress?
    @State private var expanded: Bool

    init(text: String, isActive: Bool, progress: ChatProgress?) {
        self.text = text
        self.isActive = isActive
        self.progress = progress
        _expanded = State(initialValue: isActive)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(ChatPalette.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatPalette.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(ChatPalette.tertiary)
        .disclosureGroupStyle(ChatLeadingDisclosureStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isActive) { _, active in
            expanded = active
        }
    }

    private var label: String {
        if isActive {
            if let progress {
                return "\(progress.title) · \(progress.detail)"
            }
            return "Thinking"
        }
        return "Thought it through"
    }
}

private struct ChatToolChip: View {
    let tool: ChatToolCall
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChatPalette.coral)
                Text(tool.argsJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ChatPalette.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                if tool.resultChars != nil {
                    Text(resultNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(tool.truncated ? ChatPalette.coral.opacity(0.85) : ChatPalette.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Text(ChatToolSummary.headline(tool))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatPalette.tertiary)
                if tool.truncated {
                    Text("shortened")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(ChatPalette.coral.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            ChatPalette.coral.opacity(0.12),
                            in: Capsule()
                        )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(ChatPalette.tertiary)
        .disclosureGroupStyle(ChatLeadingDisclosureStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says when an answer stands on a shortened lookup. Without it, a reply
    /// that missed something the tool did return looks like the model failing
    /// rather than the budget biting.
    private var resultNote: String {
        guard let chars = tool.resultChars else { return "" }
        guard tool.truncated else { return "\(chars) characters back" }
        return "\(chars) characters back · shortened to fit, ~\(tool.droppedTokens) tokens left out"
    }
}

/// macOS `DisclosureGroup` centers its content slot. Reasoning and tool
/// cards must stay flush left with the bubble, so we own the chrome.
private struct ChatLeadingDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatPalette.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown while a turn is alive with nothing to show yet.
///
/// Two signals, deliberately. The dots carry motion, which is what makes a live
/// window feel live. The readout carries proof: a spinner spins just as happily
/// over a dead socket, so the number beside it is the part that actually
/// answers "is it stuck". It is also the only half that survives into a
/// screenshot or a snapshot test.
private struct ChatWorkingIndicator: View {
    let progress: ChatProgress
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(ChatPalette.accent)
                        .frame(width: 4, height: 4)
                        .opacity(opacity(index))
                }
            }
            Text(progress.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ChatPalette.secondary)
            Text(progress.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChatPalette.tertiary)
                .monospacedDigit()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 3
            }
        }
    }

    /// A travelling pulse rather than three synchronised blinks: three dots
    /// fading together is hard to tell from a rendering stall.
    private func opacity(_ index: Int) -> Double {
        let distance = abs(phase - Double(index))
        return 0.25 + 0.75 * max(0, 1 - min(distance, 1))
    }
}

private struct ChatStreamCaret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(ChatPalette.accent)
            .frame(width: 7, height: 2)
            .shadow(color: ChatPalette.accent.opacity(on ? 0.7 : 0.15), radius: 4)
            .opacity(on ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

private struct ChatIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? ChatPalette.label : ChatPalette.secondary)
                .frame(width: 28, height: 28)
                .background(
                    isHovering ? Color.white.opacity(0.075) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(ChatPressStyle())
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct ChatPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct ChatComposerField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        let textView = ChatSendTextView()
        textView.delegate = context.coordinator
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.onSend()
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        textView.textColor = NSColor.white
        textView.insertionPointColor = NSColor(red: 1, green: 0.20, blue: 0.14, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.minSize = NSSize(width: 0, height: 22)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.string = text
        context.coordinator.textView = textView

        scroll.documentView = textView
        scroll.hasVerticalScroller = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.clear.cgColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ChatSendTextView else { return }
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.onSend()
        }
        context.coordinator.onSend = onSend
        textView.isEditable = isEnabled
        if textView.string != text {
            textView.string = text
        }
        scroll.alphaValue = isEnabled ? 1 : 0.55
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSend: () -> Void
        weak var textView: ChatSendTextView?

        init(text: Binding<String>, onSend: @escaping () -> Void) {
            self.text = text
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

private final class ChatSendTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if isReturnKey(event), !event.modifierFlags.contains(.shift) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isReturnKey(event), event.modifierFlags.contains(.shift) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }
}

public struct AfterRayChatOverlay<Model: AfterRayChatModeling>: View {
    @ObservedObject var model: Model
    var onClose: () -> Void
    var onOpenMoment: ((String) -> Void)?
    var thumbnailLoader: RecallThumbnailLoader?
    var previewLoader: RecallChatPreviewLoader?
    var momentLoader: RecallMomentLoader?

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        onOpenMoment: ((String) -> Void)? = nil,
        thumbnailLoader: RecallThumbnailLoader? = nil,
        previewLoader: RecallChatPreviewLoader? = nil,
        momentLoader: RecallMomentLoader? = nil
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenMoment = onOpenMoment
        self.thumbnailLoader = thumbnailLoader
        self.previewLoader = previewLoader
        self.momentLoader = momentLoader
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            AfterRayChatView(
                model: model,
                onClose: onClose,
                onOpenMoment: onOpenMoment,
                thumbnailLoader: thumbnailLoader,
                previewLoader: previewLoader,
                momentLoader: momentLoader
            )
                .recallGlass(in: .rounded(14))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
