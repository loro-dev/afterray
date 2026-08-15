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
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
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
        await loadHistory(id)
    }

    public func startNew() {
        if isSending { stop() }
        selectedID = nil
        messages = []
        streamText = ""
        streamTools = []
        errorMessage = nil
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
        sendTask = Task { await self.performSend(text) }
    }

    public func stop() {
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
        errorMessage = nil
        statusMessage = nil
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
                if let conversationId = state.conversationId {
                    bindConversation(conversationId)
                }
                if state.isFinished { break }
            }
        } catch is CancellationError {
            finalizePartialStream(state)
            return
        } catch {
            if Task.isCancelled {
                finalizePartialStream(state)
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
            finalizePartialStream(state)
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
