import AfterRayRecall
import Foundation

public enum ChatScenario: String, CaseIterable, Identifiable, Sendable {
    case empty
    case short
    case streaming
    case markdown
    case tools
    case pressure
    /// A thinking model mid-turn: reasoning is streaming, nothing is visible.
    case thinking
    /// A finished answer with its reasoning kept beside it, and a turn that
    /// was stopped part-way but kept what it had.
    case reasoning
    /// The general case the thinking one is a special case of — a turn that has
    /// produced nothing at all yet, as during a cold model load.
    case waiting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .empty: "Empty"
        case .short: "Short thread"
        case .streaming: "Streaming"
        case .markdown: "Markdown"
        case .tools: "Tool calls"
        case .pressure: "Context pressure"
        case .thinking: "Thinking"
        case .reasoning: "Reasoning kept"
        case .waiting: "Waiting"
        }
    }
}

@MainActor
public final class ChatPreviewModel: ObservableObject, AfterRayChatModeling {
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

    public private(set) var scenario: ChatScenario = .markdown
    private var store: [String: [ChatMessage]] = [:]
    private var streamTask: Task<Void, Never>?
    private var nextID = 100

    public init(scenario: ChatScenario = .markdown) {
        apply(scenario)
    }

    public func apply(_ scenario: ChatScenario) {
        streamTask?.cancel()
        streamTask = nil
        self.scenario = scenario
        draft = ""
        isSending = false
        streamText = ""
        streamTools = []
        errorMessage = nil
        statusMessage = nil
        let fixture = ChatFixtures.load(scenario)
        contextUsage = ChatFixtures.usage(scenario)
        streamProgress = ChatFixtures.progress(scenario)
        // The indicator only exists mid-turn, so these scenarios must look like
        // one is running.
        isSending = streamProgress != nil
        conversations = fixture.conversations
        store = fixture.histories
        selectedID = fixture.conversations.first?.id
        messages = selectedID.flatMap { store[$0] } ?? []
        compactionNotices = ChatTranscript.compactions(in: messages)
    }

    public func refresh() async {
        isLoadingList = false
    }

    public func select(_ id: String) async {
        streamTask?.cancel()
        isSending = false
        streamText = ""
        streamTools = []
        selectedID = id
        messages = store[id] ?? []
        // Same rule as the real model: occupancy belongs to a turn, so it does
        // not survive a conversation switch.
        contextUsage = nil
        compactionNotices = ChatTranscript.compactions(in: messages)
    }

    public func startNew() {
        streamTask?.cancel()
        isSending = false
        selectedID = nil
        messages = []
        streamText = ""
        streamTools = []
        errorMessage = nil
        contextUsage = nil
        compactionNotices = []
    }

    public func deleteConversation(_ id: String) async {
        conversations.removeAll { $0.id == id }
        store[id] = nil
        if selectedID == id {
            startNew()
        }
    }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        let now = ChatFixtures.nowMs
        if selectedID == nil {
            nextID += 1
            let id = "preview-\(nextID)"
            let conversation = ChatConversation(
                id: id,
                title: String(text.prefix(24)),
                createdAtMs: now,
                updatedAtMs: now,
                messageCount: 0
            )
            conversations.insert(conversation, at: 0)
            store[id] = []
            selectedID = id
        }
        guard let conversationId = selectedID else { return }
        let user = ChatMessage.localUser(text, conversationId: conversationId, at: now)
        messages.append(user)
        store[conversationId, default: []].append(user)
        streamTask = Task { await simulateReply(for: text) }
    }

    public func stop() {
        streamTask?.cancel()
    }

    public func simulateStream() async {
        streamTask?.cancel()
        await simulateReply(for: "stream", script: ChatFixtures.streamingScript)
    }

    private func simulateReply(for _: String, script: [ChatStreamEvent]? = nil) async {
        isSending = true
        streamText = ""
        streamTools = []
        var state = ChatStreamState()
        let events = script ?? ChatFixtures.replyScript
        for event in events {
            if Task.isCancelled { break }
            ChatStreamReducer.apply(event, to: &state)
            streamText = state.text
            streamTools = state.tools
            if let usage = state.usage { contextUsage = usage }
            if !state.compactions.isEmpty { compactionNotices = state.compactions }
            streamProgress = state.progress
            try? await Task.sleep(for: .milliseconds(28))
        }
        if Task.isCancelled {
            persistPartial(state)
        } else {
            persistFinished(state)
        }
        isSending = false
        streamText = ""
        streamTools = []
        streamTask = nil
    }

    private func persistPartial(_ state: ChatStreamState? = nil) {
        let snapshot = state ?? ChatStreamState(text: streamText, tools: streamTools)
        guard let conversationId = selectedID else { return }
        guard !snapshot.text.isEmpty || !snapshot.tools.isEmpty else { return }
        let message = ChatMessage.localAssistant(
            snapshot.text,
            conversationId: conversationId,
            tools: snapshot.tools,
            at: ChatFixtures.nowMs
        )
        messages.append(message)
        store[conversationId, default: []].append(message)
        bump(conversationId)
    }

    private func persistFinished(_ state: ChatStreamState) {
        persistPartial(state)
    }

    private func bump(_ id: String) {
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].updatedAtMs = ChatFixtures.nowMs
            conversations[index].messageCount = store[id]?.count ?? conversations[index].messageCount
        }
    }
}

public enum ChatFixtures {
    public static let nowMs: Int64 = 1_786_708_800_000

    public static let markdownAnswer = """
    You spent the afternoon in two stretches.

    ## 14:00–14:30
    Mostly Xcode. The visible error was:

    ```swift
    error: cannot find 'ChatSend' in scope
    ```

    Then a shorter pass through Safari on the protocol notes.

    1. Slot card for 14:00
    2. Transcript around the stand-up
    3. The stack trace you copied

    > I did not fetch the whole day — just the windows those tools asked for.
    """

    public static var streamingScript: [ChatStreamEvent] {
        [
            .toolCall(name: "get_slot_card", argsJSON: #"{"at_ms":50400000}"#),
            .toolResult(name: "get_slot_card", chars: 2480),
            .token(text: "You spent the afternoon in two stretches.\n\n"),
            .token(text: "## 14:00–14:30\n"),
            .token(text: "Mostly Xcode. The visible error was:\n\n"),
            .token(text: "```swift\n"),
            .token(text: "error: cannot find 'ChatSend' in scope\n"),
        ]
    }

    public static var replyScript: [ChatStreamEvent] {
        tokenEvents(from: markdownAnswer)
    }

    public static func tokenEvents(from text: String) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
            events.append(.token(text: String(text[index..<end])))
            index = end
        }
        events.append(.done(messageId: "preview-msg", conversationId: "c-markdown"))
        return events
    }

    public static func load(_ scenario: ChatScenario) -> (conversations: [ChatConversation], histories: [String: [ChatMessage]]) {
        switch scenario {
        case .empty:
            return ([], [:])
        case .short:
            return (
                [conversation("c-short", "What did I ship?", count: 4, updated: nowMs - 3_600_000)],
                ["c-short": shortMessages]
            )
        case .reasoning:
            return (
                [conversation("c-reason", "Why the build broke", count: 3, updated: nowMs)],
                ["c-reason": reasoningMessages]
            )
        case .thinking, .waiting:
            return (
                [conversation("c-think", "Yesterday's reading", count: 1, updated: nowMs)],
                ["c-think": [
                    ChatMessage(
                        id: "u-think",
                        conversationId: "c-think",
                        role: .user,
                        content: "昨天下午我在读什么",
                        createdAtMs: nowMs - 3_000
                    )
                ]]
            )
        case .streaming:
            return (
                [conversation("c-stream", "Afternoon errors", count: 1, updated: nowMs)],
                ["c-stream": [
                    ChatMessage(
                        id: "u-stream",
                        conversationId: "c-stream",
                        role: .user,
                        content: "What broke this afternoon?",
                        createdAtMs: nowMs - 8_000
                    )
                ]]
            )
        case .markdown:
            return (
                [
                    conversation("c-markdown", "Afternoon in two stretches", count: 2, updated: nowMs - 120_000),
                    conversation("c-old", "Yesterday's meeting", count: 6, updated: nowMs - 86_400_000),
                ],
                [
                    "c-markdown": [
                        ChatMessage(
                            id: "u-md",
                            conversationId: "c-markdown",
                            role: .user,
                            content: "我今天下午在干嘛",
                            createdAtMs: nowMs - 180_000
                        ),
                        ChatMessage(
                            id: "a-md",
                            conversationId: "c-markdown",
                            role: .assistant,
                            content: markdownAnswer,
                            createdAtMs: nowMs - 120_000
                        ),
                    ],
                    "c-old": shortMessages,
                ]
            )
        case .tools:
            return (
                [conversation("c-tools", "The third error", count: 2, updated: nowMs - 40_000)],
                ["c-tools": toolMessages]
            )
        case .pressure:
            return (
                [conversation("c-pressure", "Everything since Monday", count: 4, updated: nowMs - 20_000)],
                ["c-pressure": pressureMessages]
            )
        }
    }

    /// What the header shows for each scenario. Nil is the honest default: a
    /// daemon that has not reported occupancy must not produce a meter.
    public static func usage(_ scenario: ChatScenario) -> ChatContextUsage? {
        switch scenario {
        case .empty, .short: nil
        case .markdown: ChatContextUsage(promptTokens: 3_180, windowTokens: 16_384, round: 2)
        case .streaming, .tools: ChatContextUsage(promptTokens: 6_420, windowTokens: 16_384, round: 3)
        case .pressure: ChatContextUsage(promptTokens: 13_910, windowTokens: 16_384, round: 5)
        case .thinking, .waiting:
            ChatContextUsage(promptTokens: 2_240, windowTokens: 16_384, round: 1)
        case .reasoning:
            ChatContextUsage(promptTokens: 5_050, windowTokens: 16_384, round: 2)
        }
    }

    /// The two dead-air states, frozen mid-turn.
    ///
    /// The numbers are the ones actually measured against `qwen3.6:35b-mlx`
    /// answering a two-character question: 131 reasoning deltas over ~2.4 s,
    /// and a 12.7 s cold load of the 22 GB model before its first byte.
    public static func progress(_ scenario: ChatScenario) -> ChatProgress? {
        switch scenario {
        case .thinking:
            ChatProgress(phase: .thinking, reasoningDeltas: 131, elapsedMs: 2_400, round: 1)
        case .waiting:
            ChatProgress(phase: .generating, reasoningDeltas: 0, elapsedMs: 12_700, round: 1)
        default: nil
        }
    }

    /// An answer with its reasoning stored beside it, then a turn that was
    /// stopped part-way and kept what it had produced.
    static var reasoningMessages: [ChatMessage] {
        [
            ChatMessage(
                id: "u-reason",
                conversationId: "c-reason",
                role: .user,
                content: "为什么昨天的构建挂了",
                createdAtMs: nowMs - 200_000
            ),
            ChatMessage(
                id: "a-reason",
                conversationId: "c-reason",
                role: .assistant,
                content: "The IVF length check rejected the header rav1e writes for a single-frame GOP.",
                toolLog: #"[{"name":"get_slot_card","args":{"at_ms":1},"chars":2480}]"#,
                createdAtMs: nowMs - 190_000,
                reasoning: #"[{"round":1,"text":"The user is asking about a build failure yesterday. I should look at the half hour around the last commit rather than search blindly — a slot card will show which files were open and what the terminal said."},{"round":2,"text":"The card shows an IVF header assertion. That points at the length field, not the encoder itself."}]"#,
                status: "complete",
                usageJSON: #"{"prompt_tokens":5050,"window_tokens":16384,"round":2}"#
            ),
            ChatMessage(
                id: "u-reason-2",
                conversationId: "c-reason",
                role: .user,
                content: "那前一天呢",
                createdAtMs: nowMs - 60_000
            ),
            ChatMessage(
                id: "a-reason-2",
                conversationId: "c-reason",
                role: .assistant,
                content: "On the day before, the last green build was at 18:12, and the first failure came",
                createdAtMs: nowMs - 50_000,
                reasoning: #"[{"round":1,"text":"Widen to the previous day and find the boundary between green and red."}]"#,
                status: "aborted"
            ),
        ]
    }

    /// A thread that ran out of room: a shortened lookup, then a compaction row
    /// where the daemon dropped earlier evidence to keep going.
    static var pressureMessages: [ChatMessage] {
        [
            ChatMessage(
                id: "u-pressure",
                conversationId: "c-pressure",
                role: .user,
                content: "Everything I touched since Monday, with the errors",
                createdAtMs: nowMs - 240_000
            ),
            ChatMessage(
                id: "x-pressure",
                conversationId: "c-pressure",
                role: .compaction,
                content: "Dropped 3 earlier lookups · 14.0k → 6.2k",
                createdAtMs: nowMs - 60_000
            ),
            ChatMessage(
                id: "a-pressure",
                conversationId: "c-pressure",
                role: .assistant,
                content: """
                Four days, mostly two threads.

                - **Mon–Tue** the GOP header bug, in Zed and the IVF spec
                - **Wed** the chat stream, plus the stand-up

                I could not hold all of Monday's screen text at once, so the \
                earlier detail is summarised rather than quoted.
                """,
                toolLog: ChatToolLog.encode([
                    ChatToolCall(
                        id: "p1",
                        name: "get_day_summary",
                        argsJSON: #"{"day_ms":1786622400000}"#,
                        resultChars: 3_120
                    ),
                    ChatToolCall(
                        id: "p2",
                        name: "get_slot_card",
                        argsJSON: #"{"at_ms":1786640400000}"#,
                        resultChars: 8_192,
                        truncated: true,
                        droppedTokens: 1_940
                    ),
                    ChatToolCall(
                        id: "p3",
                        name: "search_evidence",
                        argsJSON: #"{"query":"IVF length check"}"#,
                        resultChars: 2_040
                    ),
                ]),
                createdAtMs: nowMs - 20_000
            ),
        ]
    }

    private static func conversation(_ id: String, _ title: String, count: Int, updated: Int64) -> ChatConversation {
        ChatConversation(
            id: id,
            title: title,
            createdAtMs: updated - 60_000,
            updatedAtMs: updated,
            messageCount: count
        )
    }

    private static var shortMessages: [ChatMessage] {
        [
            ChatMessage(
                id: "s1",
                conversationId: "c-short",
                role: .user,
                content: "What did I ship before lunch?",
                createdAtMs: nowMs - 4_000_000
            ),
            ChatMessage(
                id: "s2",
                conversationId: "c-short",
                role: .assistant,
                content: "The slot card for 11:00–11:30 is the AfterRay settings chrome pass.",
                createdAtMs: nowMs - 3_980_000
            ),
            ChatMessage(
                id: "s3",
                conversationId: "c-short",
                role: .user,
                content: "Any tests with it?",
                createdAtMs: nowMs - 3_900_000
            ),
            ChatMessage(
                id: "s4",
                conversationId: "c-short",
                role: .assistant,
                content: "Yes — `AfterRayControlModelTests` and the settings preview in Visual Lab.",
                createdAtMs: nowMs - 3_880_000
            ),
        ]
    }

    private static var toolMessages: [ChatMessage] {
        [
            ChatMessage(
                id: "t1",
                conversationId: "c-tools",
                role: .user,
                content: "那第三件事的报错具体是什么",
                createdAtMs: nowMs - 80_000
            ),
            ChatMessage(
                id: "t2",
                conversationId: "c-tools",
                role: .assistant,
                content: "The third item is the missing `ChatSend` type. The compiler pointed at `DaemonClient.swift`.",
                toolLog: #"[{"name":"get_slot_card","args":{"at_ms":50400000},"chars":2480},{"name":"get_transcript","args":{"from_ms":50400000,"to_ms":52200000},"chars":640}]"#,
                createdAtMs: nowMs - 40_000
            ),
        ]
    }
}
