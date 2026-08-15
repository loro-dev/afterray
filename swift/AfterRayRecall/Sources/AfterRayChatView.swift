import AppKit
import SwiftUI

private enum ChatMetrics {
    static let panelWidth: CGFloat = 960
    static let panelHeight: CGFloat = 660
    static let panelRadius: CGFloat = 14
    static let sidebarWidth: CGFloat = 228
    static let bubbleRadius: CGFloat = 12
    static let gutter: CGFloat = 20
}

private enum ChatPalette {
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
    static let userFill = Color(red: 0.62, green: 0.16, blue: 0.12)
    static let userStroke = Color(red: 1.0, green: 0.36, blue: 0.26).opacity(0.38)
    static let assistantFill = Color.white.opacity(0.045)
    static let codeFill = Color.black.opacity(0.46)
}

public struct AfterRayChatView<Model: AfterRayChatModeling>: View {
    @ObservedObject var model: Model
    var onClose: () -> Void
    var onOpenMoment: ((String) -> Void)?
    var fillsAvailableSpace: Bool

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        onOpenMoment: ((String) -> Void)? = nil,
        fillsAvailableSpace: Bool = false
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenMoment = onOpenMoment
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(ChatPalette.separator)
                .frame(width: 1)
            thread
        }
        .frame(
            minWidth: fillsAvailableSpace ? 720 : ChatMetrics.panelWidth,
            minHeight: fillsAvailableSpace ? 480 : ChatMetrics.panelHeight
        )
        .frame(
            width: fillsAvailableSpace ? nil : ChatMetrics.panelWidth,
            height: fillsAvailableSpace ? nil : ChatMetrics.panelHeight
        )
        .frame(
            maxWidth: fillsAvailableSpace ? .infinity : ChatMetrics.panelWidth,
            maxHeight: fillsAvailableSpace ? .infinity : ChatMetrics.panelHeight
        )
        .background(ChatPalette.panel)
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: ChatMetrics.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ChatMetrics.panelRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(ChatPalette.accent)
                    .frame(width: 16, height: 2)
                Text("AFTERRAY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(ChatPalette.accent)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Button(action: model.startNew) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New conversation")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ChatPalette.label)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(ChatPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ChatPalette.cardStroke, lineWidth: 1)
                }
            }
            .buttonStyle(ChatPressStyle())

            if model.isLoadingList, model.conversations.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(ChatPalette.accent)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatPalette.tertiary)
                }
                .padding(.horizontal, 8)
            } else if model.conversations.isEmpty {
                Text("Past conversations will land here once afterrayd can list them.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatPalette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.conversations) { conversation in
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
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: ChatMetrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ChatPalette.sidebar)
    }

    private var thread: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ChatPalette.separator)
            messageList
            statusStrip
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ChatPalette.label)
                    .lineLimit(1)
                Text("Ask anything AfterRay has already seen.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChatPalette.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if let usage = model.contextUsage {
                    ChatContextMeter(usage: usage)
                }
                if model.isLoadingHistory {
                    ProgressView().controlSize(.small).tint(ChatPalette.accent)
                }
                ChatIconButton(symbol: "xmark", help: "Close chat", action: onClose)
            }
        }
        .padding(.horizontal, ChatMetrics.gutter)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.bubbles.isEmpty, !model.isSending {
                        emptyState
                            .padding(.top, 48)
                    }
                    ForEach(model.bubbles) { bubble in
                        if bubble.role == .compaction {
                            ChatCompactionRule(text: bubble.text)
                                .id(bubble.id)
                        } else {
                            ChatBubbleView(bubble: bubble)
                                .id(bubble.id)
                        }
                    }
                }
                .padding(.horizontal, ChatMetrics.gutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.bubbles.last?.text) { _, _ in
                if let last = model.bubbles.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: model.isSending) { _, _ in
                if let last = model.bubbles.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(ChatPalette.accent)
                .frame(width: 22, height: 2)
            Text("Nothing asked yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ChatPalette.label)
            Text("AfterRay will look things up as it goes — no seeded dump of your day, just the tools it needs.")
                .font(.system(size: 12.5))
                .foregroundStyle(ChatPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
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
        HStack(alignment: .bottom, spacing: 10) {
            ChatComposerField(text: $model.draft, isEnabled: !model.isSending, onSend: model.send)
                .frame(minHeight: 44, maxHeight: 120)
            if model.isSending {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(ChatPalette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(ChatPressStyle())
                .help("Stop generating")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
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
        .padding(.horizontal, ChatMetrics.gutter)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(ChatPalette.separator).frame(height: 1)
        }
    }
}

/// How full the model's context window is.
///
/// A bar rather than a number alone: the useful question is "how much room is
/// left", which a proportion answers at a glance and a token count does not.
/// It only appears once the daemon has reported a round — an app that guessed
/// would be inventing the one number the user has no way to check.
private struct ChatContextMeter: View {
    let usage: ChatContextUsage

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, 44 * usage.fraction))
            }
            .frame(width: 44, height: 4)
            Text(usage.shortLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(usage.isTight ? ChatPalette.coral : ChatPalette.tertiary)
                .monospacedDigit()
        }
        .help("Context used this turn: \(usage.promptTokens) of \(usage.windowTokens) tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window")
        .accessibilityValue("\(Int(usage.fraction * 100)) percent used")
    }

    private var tint: Color {
        usage.isTight ? ChatPalette.coral : ChatPalette.accent.opacity(0.75)
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

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? ChatPalette.accent : .clear)
                    .frame(width: 2, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? ChatPalette.label : ChatPalette.secondary)
                        .lineLimit(2)
                    Text("\(ChatTimeLabel.listTimestamp(ms: conversation.updatedAtMs)) · \(conversation.messageCount)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChatPalette.tertiary)
                }
                Spacer(minLength: 4)
                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ChatPalette.tertiary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete conversation")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatPressStyle())
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.085) }
        return isHovering ? Color.white.opacity(0.045) : .clear
    }
}

private struct ChatBubbleView: View {
    let bubble: ChatBubble
    @State private var toolsExpanded = false
    @State private var reasoningExpanded = false

    var body: some View {
        HStack {
            if bubble.role == .user { Spacer(minLength: 48) }
            VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
                if !bubble.reasoning.isEmpty {
                    reasoningChip
                }
                if !bubble.tools.isEmpty {
                    toolChip
                }
                if !bubble.text.isEmpty || bubble.isStreaming {
                    bubbleBody
                }
            }
            .frame(maxWidth: 560, alignment: bubble.role == .user ? .trailing : .leading)
            if bubble.role == .assistant { Spacer(minLength: 48) }
        }
    }

    /// Says when an answer stands on a shortened lookup. Without it, a reply
    /// that missed something the tool did return looks like the model failing
    /// rather than the budget biting.
    private func resultNote(chars: Int, tool: ChatToolCall) -> String {
        guard tool.truncated else { return "\(chars) characters back" }
        return "\(chars) characters back · shortened to fit, ~\(tool.droppedTokens) tokens left out"
    }

    /// The model's reasoning, folded away.
    ///
    /// Collapsed by default and never streamed: it is long, unedited, and for
    /// "what did I do today" the user wants the answer, not the deliberation.
    /// Kept reachable because when an answer looks wrong, the reasoning is
    /// usually where the wrongness is visible.
    private var reasoningChip: some View {
        DisclosureGroup(isExpanded: $reasoningExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(bubble.reasoning) { round in
                    VStack(alignment: .leading, spacing: 3) {
                        if bubble.reasoning.count > 1 {
                            Text("Round \(round.round)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ChatPalette.tertiary)
                        }
                        Text(round.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ChatPalette.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(reasoningLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatPalette.tertiary)
        }
        .tint(ChatPalette.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var reasoningLabel: String {
        bubble.reasoning.count > 1
            ? "Thought it through in \(bubble.reasoning.count) rounds"
            : "Thought it through"
    }

    private var toolChip: some View {
        DisclosureGroup(isExpanded: $toolsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(bubble.tools) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ChatPalette.coral)
                        Text(tool.argsJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ChatPalette.secondary)
                            .textSelection(.enabled)
                        if let chars = tool.resultChars {
                            Text(resultNote(chars: chars, tool: tool))
                                .font(.system(size: 10.5))
                                .foregroundStyle(tool.truncated ? ChatPalette.coral.opacity(0.85) : ChatPalette.tertiary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 5) {
                Text(ChatToolSummary.collapsed(bubble.tools))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatPalette.tertiary)
                if bubble.hasTruncatedEvidence {
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
            }
        }
        .tint(ChatPalette.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bubble.role == .user {
                Text(bubble.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ChatPalette.label)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The indicator replaces the caret rather than joining it. A
                // blinking caret in front of no text reads as "waiting for you";
                // this reads as "waiting for me".
                if let progress = bubble.progress, bubble.text.isEmpty {
                    ChatWorkingIndicator(progress: progress)
                } else {
                    ChatMarkdownView(blocks: bubble.markdownBlocks)
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
    }

    private var bubbleBackground: Color {
        bubble.role == .user ? ChatPalette.userFill.opacity(0.92) : ChatPalette.assistantFill
    }

    private var bubbleStroke: Color {
        bubble.role == .user ? ChatPalette.userStroke : ChatPalette.cardStroke
    }
}

private struct ChatMarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(StreamingMarkdown.attributedInline(text))
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .foregroundStyle(ChatPalette.label)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(StreamingMarkdown.attributedInline(text))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChatPalette.label)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .bulletedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(ChatPalette.coral.opacity(0.85))
                                    .frame(width: 4, height: 4)
                                    .padding(.bottom, 1)
                                Text(StreamingMarkdown.attributedInline(item))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ChatPalette.label)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .numberedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(ChatPalette.coral)
                                    .monospacedDigit()
                                Text(StreamingMarkdown.attributedInline(item))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ChatPalette.label)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let language, let text, let closed):
                    ChatCodeBlock(language: language, text: text, closed: closed)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(ChatPalette.accent.opacity(0.7))
                            .frame(width: 2)
                        Text(StreamingMarkdown.attributedInline(text))
                            .font(.system(size: 13, weight: .medium))
                            .italic()
                            .foregroundStyle(ChatPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .rule:
                    Rectangle()
                        .fill(ChatPalette.separator)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        default: 13.5
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let text: String
    let closed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((language?.isEmpty == false ? language! : "code").uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(ChatPalette.coral.opacity(0.9))
                Spacer()
                if !closed {
                    Text("streaming")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ChatPalette.tertiary)
                }
            }
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(ChatPalette.codeFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ChatPalette.accent.opacity(0.75))
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 28)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.string = text
        context.coordinator.textView = textView

        scroll.documentView = textView
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.085).cgColor
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

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        onOpenMoment: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.onClose = onClose
        self.onOpenMoment = onOpenMoment
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            AfterRayChatView(model: model, onClose: onClose, onOpenMoment: onOpenMoment)
                .recallGlass(in: .rounded(14))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
