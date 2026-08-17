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
    var streamReasoning: [ChatReasoningRound] { get }
    /// Think / tool segments in arrival order for the turn in flight.
    /// Prefer this over `streamReasoning` + `streamTools`, which flatten it.
    var streamParts: [ChatMessagePart] { get }
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
    /// Elapsed work for the last finished turn, while this session still
    /// remembers it. History reloads fall back to the user→assistant gap.
    var lastWorkElapsedMs: Int? { get }

    func refresh() async
    func select(_ id: String) async
    func startNew()
    func deleteConversation(_ id: String) async
    func send()
    func stop()
    var chatModels: [ChatModelChoice] { get }
    var selectedChatModelID: String? { get }
    func selectChatModel(_ id: String)
}

public extension AfterRayChatModeling {
    var selectedTitle: String {
        conversations.first(where: { $0.id == selectedID })?.title ?? "New conversation"
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var streamParts: [ChatMessagePart] {
        ChatMessagePart.reconstruct(reasoning: streamReasoning, tools: streamTools)
    }

    var lastWorkElapsedMs: Int? { nil }

    var selectedConversation: ChatConversation? {
        conversations.first(where: { $0.id == selectedID })
    }

    var chatModels: [ChatModelChoice] { ChatModelChoice.previewCatalog }

    var selectedChatModelID: String? { chatModels.first?.id }

    func selectChatModel(_ id: String) {}

    var selectedChatModelTitle: String {
        chatModels.first(where: { $0.id == selectedChatModelID })?.title
            ?? chatModels.first?.title
            ?? "Model"
    }

    var bubbles: [ChatBubble] {
        ChatTranscript.bubbles(
            messages: messages,
            streamingText: streamText,
            streamingTools: streamTools,
            streamingReasoning: streamReasoning,
            streamingParts: streamParts,
            isSending: isSending,
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            liveCompactions: isSending ? compactionNotices : [],
            progress: streamProgress,
            lastWorkElapsedMs: lastWorkElapsedMs
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
    @Published public private(set) var streamReasoning: [ChatReasoningRound] = []
    @Published public private(set) var streamParts: [ChatMessagePart] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var contextUsage: ChatContextUsage?
    @Published public private(set) var compactionNotices: [ChatCompactionNotice] = []
    @Published public private(set) var streamProgress: ChatProgress?
    @Published public private(set) var lastWorkElapsedMs: Int?
    @Published public private(set) var chatModels: [ChatModelChoice] = ChatModelChoice.previewCatalog
    @Published public private(set) var selectedChatModelID: String? = ChatModelChoice.previewCatalog.first?.id

    private let daemon: any AfterRayChatServing
    private var sendTask: Task<Void, Never>?
    private var streamPresentationTask: Task<Void, Never>?
    private var pendingStreamPresentation: ChatStreamState?
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
        await refreshChatModels()
    }

    private func refreshChatModels() async {
        guard let host = daemon as? any AfterRayDaemonServing else { return }
        let library = try? await host.modelLibrary()
        let settings = try? await host.settings()
        let ollama = (try? await host.probeLlm(provider: .ollama, baseUrl: nil))?.models ?? []
        let catalog = ChatModelChoice.catalog(
            packs: library?.packs ?? [],
            ollamaModels: ollama,
            settings: settings
        )
        if !catalog.models.isEmpty {
            chatModels = catalog.models
            selectedChatModelID = catalog.selectedID
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

    public func selectChatModel(_ id: String) {
        guard chatModels.contains(where: { $0.id == id }) else { return }
        selectedChatModelID = id
        Task { await persistChatModel(id) }
    }

    private func persistChatModel(_ id: String) async {
        guard let host = daemon as? any AfterRayDaemonServing else { return }
        let provider: LlmProvider
        let modelName: String
        if id.hasPrefix(ChatModelChoice.ollamaPrefix) {
            provider = .ollama
            modelName = String(id.dropFirst(ChatModelChoice.ollamaPrefix.count))
        } else if id.hasPrefix(ChatModelChoice.builtinPrefix) {
            provider = .mlxLocal
            modelName = String(id.dropFirst(ChatModelChoice.builtinPrefix.count))
        } else if id.hasPrefix(ChatModelChoice.remotePrefix) {
            provider = .openaiCompatible
            modelName = String(id.dropFirst(ChatModelChoice.remotePrefix.count))
        } else {
            return
        }
        do {
            _ = try await host.updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: provider,
                llmBaseUrl: nil,
                llmModel: modelName,
                llmApiKey: nil,
                storageLimitBytes: nil,
                uiLanguage: nil,
                summaryLanguage: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func startNew() {
        if isSending { stop() }
        cancelStreamPresentation()
        selectedID = nil
        messages = []
        streamText = ""
        streamTools = []
        streamReasoning = []
        streamParts = []
        streamProgress = nil
        lastWorkElapsedMs = nil
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
        streamReasoning = []
        streamParts = []
        streamProgress = nil
        lastWorkElapsedMs = nil
        cancelStreamPresentation()
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
        cancelStreamPresentation()
        conversations = []
        selectedID = nil
        messages = []
        draft = ""
        isSending = false
        streamText = ""
        streamTools = []
        streamReasoning = []
        streamParts = []
        streamProgress = nil
        errorMessage = nil
        statusMessage = nil
        contextUsage = nil
        compactionNotices = []
        lastWorkElapsedMs = nil
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
                scheduleStreamPresentation(
                    state,
                    immediately: !event.isTextDelta
                )
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
        cancelStreamPresentation()
        do {
            let result = try await daemon.chatSend(conversationID: selectedID, message: text)
            bindConversation(result.conversationId)
            await loadHistory(result.conversationId)
            await refresh()
            streamText = ""
            streamTools = []
            streamReasoning = []
            streamProgress = nil
            errorMessage = nil
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = Self.disconnectedNote(from: error)
        }
    }

    private func finishSuccessfulTurn(_ state: ChatStreamState) async {
        presentStream(state)
        cancelStreamPresentation()
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
        streamReasoning = []
        streamParts = []
        streamProgress = nil
        if state.lastElapsedMs > 0 {
            lastWorkElapsedMs = state.lastElapsedMs
        }
    }

    /// Settle a turn that ended early.
    ///
    /// The daemon has been writing the answer into its row since before the
    /// first token, so the truth is in the vault. Reloading picks up exactly
    /// what was produced — including the reasoning — instead of leaving a local
    /// message whose id no reload would ever match.
    private func reloadAfterInterruption() async {
        cancelStreamPresentation()
        streamText = ""
        streamTools = []
        streamReasoning = []
        streamParts = []
        streamProgress = nil
        guard let conversationId = selectedID, !conversationId.isEmpty else { return }
        await loadHistory(conversationId)
    }

    private func finalizePartialStream(_ state: ChatStreamState? = nil) {
        cancelStreamPresentation()
        let snapshot = state ?? ChatStreamState(
            text: streamText,
            tools: streamTools,
            reasoning: streamReasoning,
            parts: streamParts
        )
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
        streamReasoning = []
        streamParts = []
        streamProgress = nil
    }

    /// Token and reasoning traffic can be much faster than the display.
    /// Publishing at most once per 33 ms keeps layout and bottom-follow near
    /// 30 Hz while tool/progress/done events remain immediate.
    private func scheduleStreamPresentation(
        _ state: ChatStreamState,
        immediately: Bool
    ) {
        pendingStreamPresentation = state
        if immediately {
            streamPresentationTask?.cancel()
            streamPresentationTask = nil
            flushStreamPresentation()
            return
        }
        guard streamPresentationTask == nil else { return }
        streamPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled, let self else { return }
            self.streamPresentationTask = nil
            self.flushStreamPresentation()
        }
    }

    private func flushStreamPresentation() {
        guard let pendingStreamPresentation else { return }
        self.pendingStreamPresentation = nil
        presentStream(pendingStreamPresentation)
    }

    private func presentStream(_ state: ChatStreamState) {
        if streamText != state.text { streamText = state.text }
        if streamTools != state.tools { streamTools = state.tools }
        if streamReasoning != state.reasoning { streamReasoning = state.reasoning }
        if streamParts != state.parts { streamParts = state.parts }
        if streamProgress != state.progress { streamProgress = state.progress }
        if let usage = state.usage, contextUsage != usage { contextUsage = usage }
        if !state.compactions.isEmpty, compactionNotices != state.compactions {
            compactionNotices = state.compactions
        }
    }

    private func cancelStreamPresentation() {
        streamPresentationTask?.cancel()
        streamPresentationTask = nil
        pendingStreamPresentation = nil
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
