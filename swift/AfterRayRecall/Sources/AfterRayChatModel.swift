import Foundation

@MainActor
public protocol AfterRayChatModeling: ObservableObject {
    var conversations: [ChatConversation] { get }
    var selectedID: String? { get }
    var messages: [ChatMessage] { get }
    var draft: String { get set }
    var isSending: Bool { get }
    var isLoadingList: Bool { get }
    var isLoadingHistory: Bool { get }
    var streamText: String { get }
    var streamTools: [ChatToolCall] { get }
    var errorMessage: String? { get }
    var statusMessage: String? { get }
    /// Context occupancy for the turn in progress, or the last one in this
    /// conversation. Nil when unknown — an older daemon says nothing, and the
    /// header then shows nothing rather than a wrong number.
    var contextUsage: ChatContextUsage? { get }
    /// Passes where the daemon dropped earlier evidence, live and restored.
    var compactionNotices: [ChatCompactionNotice] { get }
    /// Set while the turn is alive but has nothing to show yet. Nil the rest of
    /// the time, including before a turn starts.
    var streamProgress: ChatProgress? { get }

    func refresh() async
    func select(_ id: String) async
    func startNew()
    func deleteConversation(_ id: String) async
    func send()
    func stop()
}

public extension AfterRayChatModeling {
    var selectedTitle: String {
        conversations.first(where: { $0.id == selectedID })?.title ?? "New conversation"
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bubbles: [ChatBubble] {
        ChatTranscript.bubbles(
            messages: messages,
            streamingText: streamText,
            streamingTools: streamTools,
            isSending: isSending,
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            liveCompactions: isSending ? compactionNotices : [],
            progress: streamProgress
        )
    }
}

@MainActor
public final class AfterRayChatModel: ObservableObject, AfterRayChatModeling {
    @Published public private(set) var conversations: [ChatConversation] = []
    @Published public private(set) var selectedID: String?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public var draft = ""
    @Published public private(set) var isSending = false
    @Published public private(set) var isLoadingList = false
    @Published public private(set) var isLoadingHistory = false
    @Published public private(set) var streamText = ""
    @Published public private(set) var streamTools: [ChatToolCall] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var contextUsage: ChatContextUsage?
    @Published public private(set) var compactionNotices: [ChatCompactionNotice] = []
    @Published public private(set) var streamProgress: ChatProgress?

    private let daemon: any AfterRayChatServing
    private var sendTask: Task<Void, Never>?
    private var clock: () -> Int64

    public init(
        daemon: any AfterRayChatServing,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.daemon = daemon
        self.clock = clock
    }

    public func refresh() async {
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            conversations = try await daemon.chatList()
            errorMessage = nil
            statusMessage = nil
            // A brand-new conversation can exist on the wire before ChatList
            // has it. Don't throw away the open thread just because the list
            // is a beat behind.
        } catch {
            conversations = []
            statusMessage = Self.disconnectedNote(from: error)
            errorMessage = error.localizedDescription
        }
    }

    public func select(_ id: String) async {
        if isSending { stop() }
        selectedID = id
        // Occupancy belongs to a turn, not to the app. Carrying it across a
        // conversation switch would show this thread the previous one's
        // pressure — and the number looks authoritative enough to be believed.
        contextUsage = nil
        compactionNotices = []
        await loadHistory(id)
    }

    public func startNew() {
        if isSending { stop() }
        selectedID = nil
        messages = []
        streamText = ""
        streamTools = []
        streamProgress = nil
        errorMessage = nil
        contextUsage = nil
        compactionNotices = []
    }

    public func deleteConversation(_ id: String) async {
        if selectedID == id, isSending { stop() }
        do {
            try await daemon.chatDelete(conversationID: id)
            conversations.removeAll { $0.id == id }
            if selectedID == id {
                startNew()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = Self.disconnectedNote(from: error)
        }
    }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        errorMessage = nil
        statusMessage = nil
        messages.append(.localUser(text, conversationId: selectedID, at: clock()))
        isSending = true
        streamText = ""
        streamTools = []
        streamProgress = nil
        // A new turn starts from this conversation's stored history, not from
        // the last turn's live notices.
        compactionNotices = ChatTranscript.compactions(in: messages)
        sendTask = Task { await self.performSend(text) }
    }

    /// Stop generating.
    ///
    /// Tells the daemon explicitly before dropping the stream. Dropping alone
    /// is indistinguishable from closing the panel, which the daemon
    /// deliberately treats as "I will read it later" and lets run to the end.
    public func stop() {
        if let conversationId = selectedID, !conversationId.isEmpty {
            let daemon = daemon
            Task { try? await daemon.chatAbort(conversationID: conversationId) }
        }
        sendTask?.cancel()
    }

    public func clearSensitiveState() {
        sendTask?.cancel()
        sendTask = nil
        conversations = []
        selectedID = nil
        messages = []
        draft = ""
        isSending = false
        streamText = ""
        streamTools = []
        streamProgress = nil
        errorMessage = nil
        statusMessage = nil
        contextUsage = nil
        compactionNotices = []
    }

    private func performSend(_ text: String) async {
        defer {
            isSending = false
            sendTask = nil
        }
        var state = ChatStreamState()
        var sawEvent = false
        do {
            for try await event in daemon.chatStream(conversationID: selectedID, message: text) {
                if Task.isCancelled { break }
                sawEvent = true
                ChatStreamReducer.apply(event, to: &state)
                streamText = state.text
                streamTools = state.tools
                streamProgress = state.progress
                if let usage = state.usage { contextUsage = usage }
                if !state.compactions.isEmpty { compactionNotices = state.compactions }
                if let conversationId = state.conversationId {
                    bindConversation(conversationId)
                }
                if state.isFinished { break }
            }
        } catch is CancellationError {
            await reloadAfterInterruption()
            return
        } catch {
            if Task.isCancelled {
                await reloadAfterInterruption()
                return
            }
            if sawEvent {
                errorMessage = error.localizedDescription
                finalizePartialStream(state)
                return
            }
            await sendWithoutStream(text)
            return
        }

        if Task.isCancelled {
            await reloadAfterInterruption()
            return
        }
        if state.shouldFallbackToSend {
            await sendWithoutStream(text)
            return
        }
        if let error = state.error {
            errorMessage = error
        }
        await finishSuccessfulTurn(state)
    }

    private func sendWithoutStream(_ text: String) async {
        do {
            let result = try await daemon.chatSend(conversationID: selectedID, message: text)
            bindConversation(result.conversationId)
            await loadHistory(result.conversationId)
            await refresh()
            streamText = ""
            streamTools = []
        streamProgress = nil
            errorMessage = nil
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = Self.disconnectedNote(from: error)
        }
    }

    private func finishSuccessfulTurn(_ state: ChatStreamState) async {
        if let conversationId = state.conversationId ?? selectedID, !conversationId.isEmpty {
            bindConversation(conversationId)
            await loadHistory(conversationId)
            await refresh()
        } else if !state.text.isEmpty || !state.tools.isEmpty {
            messages.append(
                .localAssistant(
                    state.text,
                    conversationId: selectedID,
                    tools: state.tools,
                    at: clock()
                )
            )
        }
        streamText = ""
        streamTools = []
        streamProgress = nil
    }

    /// Settle a turn that ended early.
    ///
    /// The daemon has been writing the answer into its row since before the
    /// first token, so the truth is in the vault. Reloading picks up exactly
    /// what was produced — including the reasoning — instead of leaving a local
    /// message whose id no reload would ever match.
    private func reloadAfterInterruption() async {
        streamText = ""
        streamTools = []
        streamProgress = nil
        guard let conversationId = selectedID, !conversationId.isEmpty else { return }
        await loadHistory(conversationId)
    }

    private func finalizePartialStream(_ state: ChatStreamState? = nil) {
        let snapshot = state ?? ChatStreamState(text: streamText, tools: streamTools)
        if !snapshot.text.isEmpty || !snapshot.tools.isEmpty {
            messages.append(
                .localAssistant(
                    snapshot.text,
                    conversationId: selectedID,
                    tools: snapshot.tools,
                    at: clock()
                )
            )
        }
        streamText = ""
        streamTools = []
        streamProgress = nil
    }

    private func bindConversation(_ id: String) {
        guard !id.isEmpty else { return }
        selectedID = id
        for index in messages.indices where messages[index].conversationId.isEmpty {
            messages[index].conversationId = id
        }
    }

    private func loadHistory(_ id: String) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            messages = try await daemon.chatHistory(conversationID: id)
            // Occupancy belongs to a turn, and the last turn in this thread
            // recorded its own. Without this a full old conversation shows no
            // meter at all until the next message — the point at which it is
            // least useful.
            //
            // Only overwritten when a row actually carries one. `select` has
            // already cleared it for a switch, so this cannot leak across
            // conversations; leaving it alone otherwise keeps the live number
            // from a turn whose row predates stored usage.
            if let restored = messages.reversed().compactMap(\.usage).first {
                contextUsage = restored
            }
            // Restored from the thread's own rows, so reopening a conversation
            // still shows where the agent stopped being able to see. Usage is
            // not restored: the daemon does not store it, and inventing one
            // would be worse than showing none.
            compactionNotices = ChatTranscript.compactions(in: messages)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = Self.disconnectedNote(from: error)
        }
    }

    static func disconnectedNote(from error: Error) -> String {
        if let daemon = error as? DaemonClientError {
            switch daemon {
            case .connection, .rejected, .protocolMismatch:
                return "Chat is wired, but afterrayd is not serving it yet."
            default:
                break
            }
        }
        return "Could not reach the AfterRay daemon."
    }
}
