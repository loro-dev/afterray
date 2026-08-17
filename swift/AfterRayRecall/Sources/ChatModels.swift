import Foundation

// MARK: - Wire types (plan C / protocol crate Conversation)

public struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var createdAtMs: Int64
    public var updatedAtMs: Int64
    public var messageCount: Int

    public init(
        id: String,
        title: String,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        messageCount: Int
    ) {
        self.id = id
        self.title = title
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case messageCount = "message_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? createdAtMs
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
    }
}

/// One row in the chat model menu. `group` is a section heading, not ALL CAPS.
public struct ChatModelChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let group: String

    public init(id: String, title: String, group: String) {
        self.id = id
        self.title = title
        self.group = group
    }

    public static let builtinPrefix = "builtin:"
    public static let ollamaPrefix = "ollama:"
    public static let remotePrefix = "remote:"

    public static let previewCatalog: [ChatModelChoice] = [
        ChatModelChoice(id: "builtin:qwen35-4b", title: "Qwen 3.5 4B", group: "Built-in"),
        ChatModelChoice(id: "ollama:llama3.2", title: "llama3.2", group: "Ollama"),
        ChatModelChoice(id: "ollama:qwen2.5", title: "qwen2.5", group: "Ollama"),
    ]

    /// One linear pass over packs + Ollama rows. Selection is the saved
    /// provider/model when it is still in the list.
    public static func catalog(
        packs: [ModelPack],
        ollamaModels: [LlmRemoteModel],
        settings: AppSettings?
    ) -> (models: [ChatModelChoice], selectedID: String?) {
        var models: [ChatModelChoice] = []
        models.reserveCapacity(packs.count + ollamaModels.count + 1)
        for pack in packs where pack.capability.contains("llm") {
            let title = pack.present ? pack.name : "\(pack.name) (not downloaded)"
            models.append(ChatModelChoice(id: builtinPrefix + pack.id, title: title, group: "Built-in"))
        }
        for remote in ollamaModels {
            models.append(
                ChatModelChoice(id: ollamaPrefix + remote.id, title: remote.name, group: "Ollama")
            )
        }
        if let settings, settings.llmProvider == .openaiCompatible {
            let name = settings.llmModel.isEmpty ? "Remote endpoint" : settings.llmModel
            models.append(ChatModelChoice(id: remotePrefix + settings.llmModel, title: name, group: "Remote"))
        }
        return (models, selectedID(in: models, settings: settings))
    }

    public static func selectedID(in models: [ChatModelChoice], settings: AppSettings?) -> String? {
        guard let settings else { return models.first?.id }
        switch settings.llmProvider {
        case .mlxLocal:
            return models.first(where: { $0.id == builtinPrefix + settings.llmModel })?.id
                ?? models.first(where: { $0.group == "Built-in" })?.id
                ?? models.first?.id
        case .ollama:
            return models.first(where: { $0.id == ollamaPrefix + settings.llmModel })?.id
                ?? models.first(where: { $0.group == "Ollama" })?.id
                ?? models.first?.id
        case .openaiCompatible:
            return models.first(where: { $0.id.hasPrefix(remotePrefix) })?.id
                ?? models.first?.id
        }
    }
}

/// Conversations bucketed by local calendar day, newest day first.
public struct ChatDayGroup: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let conversations: [ChatConversation]
}

public enum ChatConversationGrouping {
    /// Title filter, one linear pass. Empty / whitespace query is a no-op.
    public static func matching(
        _ conversations: [ChatConversation],
        query: String
    ) -> [ChatConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(needle) }
    }

    /// Sort once, then walk — O(n log n). Callers must not re-sort inside a
    /// view body per row.
    public static func days(
        _ conversations: [ChatConversation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ChatDayGroup] {
        let sorted = conversations.sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs > rhs.createdAtMs
            }
            return lhs.id > rhs.id
        }
        var groups: [ChatDayGroup] = []
        groups.reserveCapacity(min(sorted.count, 8))
        for conversation in sorted {
            let start = startOfDayMs(conversation.createdAtMs, calendar: calendar)
            if let last = groups.last, last.id == start {
                var next = last.conversations
                next.append(conversation)
                groups[groups.count - 1] = ChatDayGroup(
                    id: last.id,
                    label: last.label,
                    conversations: next
                )
            } else {
                groups.append(
                    ChatDayGroup(
                        id: start,
                        label: ChatTimeLabel.dayHeading(ms: start, now: now, calendar: calendar),
                        conversations: [conversation]
                    )
                )
            }
        }
        return groups
    }

    public static func startOfDayMs(_ ms: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        let start = calendar.startOfDay(for: date)
        return Int64(start.timeIntervalSince1970 * 1_000)
    }
}

public enum ChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    /// A row the daemon wrote where it dropped earlier evidence to stay inside
    /// the context window. Not speech: it renders as a rule across the thread,
    /// and it is never folded back into a later prompt.
    case compaction

    public init(parsing raw: String) {
        switch raw.lowercased() {
        case "user": self = .user
        case "compaction": self = .compaction
        default: self = .assistant
        }
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var conversationId: String
    public var role: ChatRole
    public var content: String
    public var toolLog: String?
    public var createdAtMs: Int64
    /// The model's reasoning, as the daemon's JSON array of rounds.
    public var reasoning: String?
    /// `streaming`, `complete` or `aborted`. Nil on rows written before turns
    /// were persisted as they ran — all of which finished.
    public var status: String?
    /// Context occupancy of the turn that wrote this row, as JSON.
    public var usageJSON: String?

    public init(
        id: String,
        conversationId: String,
        role: ChatRole,
        content: String,
        toolLog: String? = nil,
        createdAtMs: Int64,
        reasoning: String? = nil,
        status: String? = nil,
        usageJSON: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolLog = toolLog
        self.createdAtMs = createdAtMs
        self.reasoning = reasoning
        self.status = status
        self.usageJSON = usageJSON
    }

    /// Whether this row was stopped part-way. The text it holds is real; it is
    /// just not the whole of what was coming.
    public var wasAborted: Bool { status == "aborted" }

    /// Reasoning rounds, decoded. Empty when there are none.
    public var reasoningRounds: [ChatReasoningRound] {
        ChatReasoningRound.parse(reasoning)
    }

    /// Occupancy stored with this row, if the daemon recorded any.
    public var usage: ChatContextUsage? {
        guard let usageJSON, let data = usageJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let window = intValue(object["window_tokens"]) ?? 0
        guard window > 0 else { return nil }
        return ChatContextUsage(
            promptTokens: intValue(object["prompt_tokens"]) ?? 0,
            windowTokens: window,
            round: intValue(object["round"]) ?? 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case toolLog = "tool_log"
        case createdAtMs = "created_at_ms"
        case reasoning
        case status
        case usageJSON = "usage_json"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId) ?? ""
        let rawRole = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        role = ChatRole(parsing: rawRole)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolLog = try container.decodeIfPresent(String.self, forKey: .toolLog)
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        usageJSON = try container.decodeIfPresent(String.self, forKey: .usageJSON)
    }

    public var toolCalls: [ChatToolCall] { ChatToolLog.parse(toolLog) }

    /// Best-effort display order from the stored columns. See
    /// `ChatMessagePart.reconstruct` for what cannot be recovered.
    public var parts: [ChatMessagePart] {
        ChatMessagePart.reconstruct(reasoning: reasoningRounds, tools: toolCalls)
    }

    public static func localUser(_ content: String, conversationId: String?, at ms: Int64) -> ChatMessage {
        ChatMessage(
            id: "local-user-\(ms)-\(UUID().uuidString)",
            conversationId: conversationId ?? "",
            role: .user,
            content: content,
            createdAtMs: ms
        )
    }

    public static func localAssistant(
        _ content: String,
        conversationId: String?,
        tools: [ChatToolCall],
        at ms: Int64
    ) -> ChatMessage {
        ChatMessage(
            id: "local-assistant-\(ms)-\(UUID().uuidString)",
            conversationId: conversationId ?? "",
            role: .assistant,
            content: content,
            toolLog: ChatToolLog.encode(tools),
            createdAtMs: ms
        )
    }
}

public struct ChatSendResult: Equatable, Sendable {
    public var conversationId: String
    public var messageId: String?

    public init(conversationId: String, messageId: String? = nil) {
        self.conversationId = conversationId
        self.messageId = messageId
    }
}

extension ChatSendResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case assistantMessageId = "assistant_message_id"
        case conversation
        case id
    }

    private struct NestedConversation: Decodable {
        let id: String
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let id = try? single.decode(String.self)
        {
            self.init(conversationId: id)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The daemon answers a send with the whole conversation plus the id of
        // the message it just wrote, so the id lives one level down and under
        // a different name than the stream's `done` event uses.
        if let nested = try container.decodeIfPresent(
            NestedConversation.self,
            forKey: .conversation
        ) {
            self.init(
                conversationId: nested.id,
                messageId: try container.decodeIfPresent(
                    String.self,
                    forKey: .assistantMessageId
                ) ?? container.decodeIfPresent(String.self, forKey: .messageId)
            )
            return
        }
        if let id = try container.decodeIfPresent(String.self, forKey: .conversationId) {
            self.init(
                conversationId: id,
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId)
            )
            return
        }
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.init(
                conversationId: id,
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId)
            )
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "ChatSend is missing conversation_id")
        )
    }
}

public struct ChatHistoryPayload: Equatable, Sendable {
    public var messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        self.messages = messages
    }
}

extension ChatHistoryPayload: Decodable {
    enum CodingKeys: String, CodingKey {
        case messages
    }

    public init(from decoder: Decoder) throws {
        if let array = try? [ChatMessage](from: decoder) {
            messages = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }
}

public struct ChatListPayload: Equatable, Sendable {
    public var conversations: [ChatConversation]

    public init(conversations: [ChatConversation]) {
        self.conversations = conversations
    }
}

extension ChatListPayload: Decodable {
    enum CodingKeys: String, CodingKey {
        case conversations
    }

    public init(from decoder: Decoder) throws {
        if let array = try? [ChatConversation](from: decoder) {
            conversations = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decodeIfPresent([ChatConversation].self, forKey: .conversations) ?? []
    }
}

// MARK: - Stream events (plan B kinds, consumed by C)

/// How full the model's context window was on one round.
public struct ChatContextUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var windowTokens: Int
    public var round: Int

    public init(promptTokens: Int, windowTokens: Int, round: Int) {
        self.promptTokens = promptTokens
        self.windowTokens = windowTokens
        self.round = round
    }

    /// Occupancy, clamped. Zero when the daemon did not say what the window is.
    public var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return min(1, Double(promptTokens) / Double(windowTokens))
    }

    /// Past the point where the next long tool result will start costing
    /// evidence. The threshold is a UI decision, not the daemon's: the daemon
    /// compacts when it must, and this is the warning before that happens.
    public var isTight: Bool { fraction >= 0.75 }

    public var shortLabel: String {
        "\(ChatContextUsage.compact(promptTokens)) / \(ChatContextUsage.compact(windowTokens))"
    }

    static func compact(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        let thousands = Double(tokens) / 1_000
        return thousands < 10
            ? String(format: "%.1fk", thousands)
            : "\(Int(thousands.rounded()))k"
    }
}

/// One round's reasoning, as stored beside the answer it produced.
public struct ChatReasoningRound: Equatable, Identifiable, Sendable {
    public var round: Int
    public var text: String

    public var id: Int { round }

    public init(round: Int, text: String) {
        self.round = round
        self.text = text
    }

    static func parse(_ raw: String?) -> [ChatReasoningRound] {
        guard let raw, let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            return ChatReasoningRound(round: intValue(row["round"]) ?? 0, text: text)
        }
    }
}

/// Proof that a turn is alive while it has nothing to show.
///
/// Three separate stretches leave the window empty and only one is about
/// thinking models: a model streaming reasoning, a cold load before the first
/// byte, and the generation of a tool call the answer gate hides. They look
/// identical from here, and the user's question in all three is the same one.
public struct ChatProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case generating
        case thinking

        /// Unknown phases fall back to `generating` rather than being dropped:
        /// a newer daemon inventing one must not blank the indicator.
        public init(parsing raw: String) {
            self = raw == "thinking" ? .thinking : .generating
        }
    }

    public var phase: Phase
    public var reasoningDeltas: Int
    public var elapsedMs: Int
    public var round: Int

    public init(phase: Phase, reasoningDeltas: Int, elapsedMs: Int, round: Int) {
        self.phase = phase
        self.reasoningDeltas = reasoningDeltas
        self.elapsedMs = elapsedMs
        self.round = round
    }

    public var title: String {
        phase == .thinking ? "Thinking" : "Working"
    }

    /// Elapsed time is honest and readable. `reasoningDeltas` is transport
    /// activity, not a count of semantic steps, so it must not be presented as
    /// one to the user.
    public var detail: String {
        Self.formatElapsed(elapsedMs)
    }

    public static func formatElapsed(_ elapsedMs: Int) -> String {
        let value = Double(max(elapsedMs, 0)) / 1_000
        return value < 10
            ? String(format: "%.1fs", value)
            : "\(Int(value.rounded()))s"
    }
}

/// One pass where the daemon dropped earlier evidence to make room.
public struct ChatCompactionNotice: Equatable, Identifiable, Sendable {
    public var id: String
    public var strategy: String
    public var fromRound: Int
    public var toRound: Int
    public var tokensBefore: Int
    public var tokensAfter: Int

    public init(
        id: String = UUID().uuidString,
        strategy: String,
        fromRound: Int,
        toRound: Int,
        tokensBefore: Int,
        tokensAfter: Int
    ) {
        self.id = id
        self.strategy = strategy
        self.fromRound = fromRound
        self.toRound = toRound
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
    }

    public var droppedResults: Int { max(1, toRound - fromRound + 1) }

    /// The line drawn across the thread. It says what went and that it is
    /// recoverable — a shorter answer with no explanation just reads as the
    /// assistant getting worse.
    public var summary: String {
        let noun = droppedResults == 1 ? "lookup" : "lookups"
        // Deliberately short: this is a rule across the thread, and a line that
        // wraps stops reading as a divider and starts reading as a message.
        let counts = tokensBefore > 0
            ? " · \(ChatContextUsage.compact(tokensBefore)) → \(ChatContextUsage.compact(tokensAfter))"
            : ""
        return "Dropped \(droppedResults) earlier \(noun)\(counts)"
    }
}

public enum ChatStreamEvent: Equatable, Sendable {
    case toolCall(name: String, argsJSON: String)
    case toolResult(name: String, chars: Int, truncated: Bool = false, dropped: Int = 0)
    case token(text: String)
    case reasoning(text: String, round: Int)
    case usage(ChatContextUsage)
    case started(messageId: String, conversationId: String)
    case progress(ChatProgress)
    case compaction(ChatCompactionNotice)
    case done(messageId: String, conversationId: String)
    case error(message: String)

    public var isTerminal: Bool {
        switch self {
        case .done, .error: true
        default: false
        }
    }
}

public enum ChatStreamEventDecoder {
    /// Accepts a bare plan event or a daemon `Response` envelope whose `data` is the event.
    ///
    /// Returns `nil` for a line this build does not understand. The daemon's
    /// event set is additive, and an app that threw on an unfamiliar `kind`
    /// would turn every new daemon event into a broken chat window — the two
    /// ship separately and cannot be upgraded in lockstep.
    public static func decode(line: Data) throws -> ChatStreamEvent? {
        let trimmed = line.trimmingASCIINewlines()
        if trimmed.isEmpty { return nil }
        let object = try JSONSerialization.jsonObject(with: trimmed)
        guard let root = object as? [String: Any] else {
            throw DaemonClientError.invalidResponse
        }
        if let kind = root["kind"] as? String {
            return parse(kind: kind, object: root)
        }
        if let ok = root["ok"] as? Bool {
            if let version = root["protocol_version"] as? Int,
               version != UnixSocketDaemonClient.protocolVersion
            {
                throw DaemonClientError.protocolMismatch(version)
            }
            if !ok {
                return .error(message: root["error"] as? String ?? "Unknown daemon error")
            }
            guard let data = root["data"] as? [String: Any] else {
                throw DaemonClientError.missingData
            }
            if let kind = data["kind"] as? String {
                return parse(kind: kind, object: data)
            }
            throw DaemonClientError.invalidResponse
        }
        throw DaemonClientError.invalidResponse
    }

    private static func parse(kind: String, object: [String: Any]) -> ChatStreamEvent? {
        switch kind {
        case "tool_call":
            let name = object["name"] as? String ?? "tool"
            return .toolCall(name: name, argsJSON: stringifyJSON(object["args"]))
        case "tool_result":
            let name = object["name"] as? String ?? "tool"
            return .toolResult(
                name: name,
                chars: intValue(object["chars"]) ?? 0,
                truncated: object["truncated"] as? Bool ?? false,
                dropped: intValue(object["dropped"]) ?? 0
            )
        case "token":
            return .token(text: object["text"] as? String ?? "")
        case "reasoning":
            return .reasoning(
                text: object["text"] as? String ?? "",
                round: intValue(object["round"]) ?? 0
            )
        case "usage":
            return .usage(
                ChatContextUsage(
                    promptTokens: intValue(object["prompt_tokens"]) ?? 0,
                    windowTokens: intValue(object["window_tokens"]) ?? 0,
                    round: intValue(object["round"]) ?? 0
                )
            )
        case "started":
            return .started(
                messageId: object["message_id"] as? String ?? "",
                conversationId: object["conversation_id"] as? String ?? ""
            )
        case "progress":
            return .progress(
                ChatProgress(
                    phase: ChatProgress.Phase(parsing: object["phase"] as? String ?? ""),
                    reasoningDeltas: intValue(object["reasoning_deltas"]) ?? 0,
                    elapsedMs: intValue(object["elapsed_ms"]) ?? 0,
                    round: intValue(object["round"]) ?? 0
                )
            )
        case "compaction":
            let from = intValue(object["from_round"]) ?? 0
            let to = intValue(object["to_round"]) ?? from
            return .compaction(
                ChatCompactionNotice(
                    id: "compaction-\(from)-\(to)",
                    strategy: object["strategy"] as? String ?? "compaction",
                    fromRound: from,
                    toRound: to,
                    tokensBefore: intValue(object["tokens_before"]) ?? 0,
                    tokensAfter: intValue(object["tokens_after"]) ?? 0
                )
            )
        case "done":
            let messageId = object["message_id"] as? String ?? ""
            let conversationId = object["conversation_id"] as? String ?? ""
            return .done(messageId: messageId, conversationId: conversationId)
        case "error":
            return .error(message: object["message"] as? String ?? "Chat failed")
        default:
            return nil
        }
    }
}

/// One visible stretch of an assistant turn, in the order it arrived.
///
/// The answer stays on `ChatBubble.text` so Markdown can keep streaming as
/// one block. These parts are the work that happened before (and between)
/// that text: a thought, a lookup, another thought.
public enum ChatMessagePart: Equatable, Identifiable, Sendable {
    case reasoning(id: String, round: Int, text: String)
    case tool(ChatToolCall)

    public var id: String {
        switch self {
        case .reasoning(let id, _, _): id
        case .tool(let call): call.id
        }
    }

    public static func tools(in parts: [ChatMessagePart]) -> [ChatToolCall] {
        parts.compactMap { part in
            if case .tool(let call) = part { return call }
            return nil
        }
    }

    public static func reasoning(in parts: [ChatMessagePart]) -> [ChatReasoningRound] {
        parts.compactMap { part in
            if case .reasoning(_, let round, let text) = part {
                return ChatReasoningRound(round: round, text: text)
            }
            return nil
        }
    }

    /// Rebuild arrival order from the two stored columns.
    ///
    /// The vault keeps `reasoning` and `tool_log` apart, so the live
    /// think → tool → think sequence is not recorded. This assumes the
    /// usual ReAct shape: one tool between consecutive reasoning rounds,
    /// leftover tools after the last thought. A tool-first turn, or two
    /// tools then a thought, cannot be recovered.
    public static func reconstruct(
        reasoning: [ChatReasoningRound],
        tools: [ChatToolCall]
    ) -> [ChatMessagePart] {
        var parts: [ChatMessagePart] = []
        parts.reserveCapacity(reasoning.count + tools.count)
        var toolIndex = 0
        for (index, round) in reasoning.enumerated() {
            parts.append(
                .reasoning(
                    id: "stored-reason-\(round.round)-\(index)",
                    round: round.round,
                    text: round.text
                )
            )
            let isLastThought = index == reasoning.count - 1
            if isLastThought {
                while toolIndex < tools.count {
                    parts.append(.tool(tools[toolIndex]))
                    toolIndex += 1
                }
            } else if toolIndex < tools.count {
                parts.append(.tool(tools[toolIndex]))
                toolIndex += 1
            }
        }
        while toolIndex < tools.count {
            parts.append(.tool(tools[toolIndex]))
            toolIndex += 1
        }
        return parts
    }
}

public struct ChatStreamState: Equatable, Sendable {
    public var text: String
    /// Think / tool segments in event-arrival order. Do not flatten this
    /// into `reasoning` + `tools` and render those separately — that is
    /// what used to merge every thought into one chip above every tool.
    public var parts: [ChatMessagePart]
    public var conversationId: String?
    public var messageId: String?
    public var error: String?
    public var isFinished: Bool
    /// The most recent round's occupancy. Nil until the daemon reports one, so
    /// an older daemon simply shows no meter rather than showing a wrong one.
    public var usage: ChatContextUsage?
    public var compactions: [ChatCompactionNotice]
    /// Set while the turn is alive with nothing to show, cleared the moment
    /// there is something. Nil is the normal state, not an error.
    public var progress: ChatProgress?
    /// Highest elapsed the daemon reported this turn. `progress` is cleared
    /// when the first token arrives, so the folded summary after the answer
    /// still needs this.
    public var lastElapsedMs: Int

    public init(
        text: String = "",
        tools: [ChatToolCall] = [],
        reasoning: [ChatReasoningRound] = [],
        parts: [ChatMessagePart]? = nil,
        conversationId: String? = nil,
        messageId: String? = nil,
        error: String? = nil,
        isFinished: Bool = false,
        usage: ChatContextUsage? = nil,
        compactions: [ChatCompactionNotice] = [],
        progress: ChatProgress? = nil,
        lastElapsedMs: Int = 0
    ) {
        self.text = text
        self.parts = parts ?? ChatMessagePart.reconstruct(reasoning: reasoning, tools: tools)
        self.conversationId = conversationId
        self.messageId = messageId
        self.error = error
        self.isFinished = isFinished
        self.usage = usage
        self.compactions = compactions
        self.progress = progress
        self.lastElapsedMs = lastElapsedMs
    }

    public var tools: [ChatToolCall] { ChatMessagePart.tools(in: parts) }

    public var reasoning: [ChatReasoningRound] { ChatMessagePart.reasoning(in: parts) }

    public var receivedWork: Bool {
        !text.isEmpty || !parts.isEmpty
    }

    public var shouldFallbackToSend: Bool {
        isFinished && !receivedWork && error != nil
    }
}

public enum ChatStreamReducer {
    public static func apply(_ event: ChatStreamEvent, to state: inout ChatStreamState) {
        switch event {
        case .toolCall(let name, let argsJSON):
            // The tool row takes over as the visible sign of work.
            state.progress = nil
            state.parts.append(
                .tool(
                    ChatToolCall(
                        id: "tool-\(state.parts.count)-\(name)",
                        name: name,
                        argsJSON: argsJSON
                    )
                )
            )
        case .toolResult(let name, let chars, let truncated, let dropped):
            if let index = state.parts.lastIndex(where: { part in
                if case .tool(let call) = part {
                    return call.name == name && call.resultChars == nil
                }
                return false
            }), case .tool(var call) = state.parts[index] {
                call.resultChars = chars
                call.truncated = truncated
                call.droppedTokens = dropped
                state.parts[index] = .tool(call)
            } else {
                state.parts.append(
                    .tool(
                        ChatToolCall(
                            id: "tool-\(state.parts.count)-\(name)",
                            name: name,
                            argsJSON: "{}",
                            resultChars: chars,
                            truncated: truncated,
                            droppedTokens: dropped
                        )
                    )
                )
            }
        case .usage(let usage):
            state.usage = usage
        case .started(let messageId, let conversationId):
            // The row already exists in the vault. Naming it now is what stops
            // the app inventing a placeholder that no reload would match.
            if !messageId.isEmpty { state.messageId = messageId }
            if !conversationId.isEmpty { state.conversationId = conversationId }
        case .progress(let progress):
            state.progress = progress
            if progress.elapsedMs > state.lastElapsedMs {
                state.lastElapsedMs = progress.elapsedMs
            }
        case .compaction(let notice):
            // A pass can be reported more than once across rounds; the range is
            // the identity, so a repeat replaces rather than stacks.
            if let index = state.compactions.firstIndex(where: { $0.id == notice.id }) {
                state.compactions[index] = notice
            } else {
                state.compactions.append(notice)
            }
        case .token(let text):
            state.text += text
            // The answer is now its own proof of life. Leaving the indicator up
            // beside it would put two "it is working" signals on screen.
            state.progress = nil
        case .reasoning(let text, let round):
            guard !text.isEmpty else { break }
            // Same-round deltas append only while that thought is still the
            // last part. A tool in between starts a new segment even if the
            // daemon reuses the round number — arrival order is the identity.
            if case .reasoning(let id, let lastRound, let existing) = state.parts.last,
               lastRound == round
            {
                state.parts[state.parts.count - 1] = .reasoning(
                    id: id,
                    round: round,
                    text: existing + text
                )
            } else {
                state.parts.append(
                    .reasoning(
                        id: "reason-\(state.parts.count)-\(round)",
                        round: round,
                        text: text
                    )
                )
            }
        case .done(let messageId, let conversationId):
            state.progress = nil
            if !messageId.isEmpty { state.messageId = messageId }
            if !conversationId.isEmpty { state.conversationId = conversationId }
            state.isFinished = true
        case .error(let message):
            state.error = message
            state.isFinished = true
        }
    }
}

extension ChatStreamEvent {
    var isTextDelta: Bool {
        switch self {
        case .token, .reasoning: true
        default: false
        }
    }
}

// MARK: - Tool calls

public struct ChatToolCall: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var argsJSON: String
    public var resultChars: Int?
    /// Whether the daemon cut this result to fit its budget. Shown on the
    /// bubble: an answer built on a shortened lookup earns the caveat.
    public var truncated: Bool
    public var droppedTokens: Int

    public init(
        id: String,
        name: String,
        argsJSON: String = "{}",
        resultChars: Int? = nil,
        truncated: Bool = false,
        droppedTokens: Int = 0
    ) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
        self.resultChars = resultChars
        self.truncated = truncated
        self.droppedTokens = droppedTokens
    }

    public var args: [String: Any] {
        guard let data = argsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

public enum ChatToolLog {
    public static func parse(_ raw: String?) -> [ChatToolCall] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let array = object as? [Any] {
            items = array.compactMap { $0 as? [String: Any] }
        } else if let single = object as? [String: Any] {
            items = [single]
        } else {
            return []
        }

        return items.enumerated().compactMap { index, item in
            let name = item["name"] as? String ?? item["tool"] as? String
            guard let name, !name.isEmpty else { return nil }
            return ChatToolCall(
                id: item["id"] as? String ?? "log-\(index)-\(name)",
                name: name,
                argsJSON: stringifyJSON(item["args"]),
                resultChars: intValue(item["chars"]),
                truncated: item["truncated"] as? Bool ?? false
            )
        }
    }

    public static func encode(_ tools: [ChatToolCall]) -> String? {
        guard !tools.isEmpty else { return nil }
        let payload: [[String: Any]] = tools.map { tool in
            var row: [String: Any] = ["name": tool.name, "args": tool.args]
            if let chars = tool.resultChars { row["chars"] = chars }
            if tool.truncated { row["truncated"] = true }
            return row
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}

public enum ChatToolSummary {
    public static func headline(
        _ call: ChatToolCall,
        calendar: Calendar = .current
    ) -> String {
        let args = call.args
        switch call.name {
        case "get_slot_card":
            if let at = int64Value(args["at_ms"]) {
                return "Looked up \(ChatTimeLabel.slotRange(atMs: at, calendar: calendar))"
            }
            return "Looked up a half-hour card"
        case "list_moments":
            if let range = windowLabel(args, calendar: calendar) {
                return "Browsed moments from \(range)"
            }
            return "Browsed the timeline"
        case "get_transcript":
            if let range = windowLabel(args, calendar: calendar) {
                return "Read the transcript from \(range)"
            }
            return "Read a transcript"
        case "list_activity":
            if let range = windowLabel(args, calendar: calendar) {
                return "Checked activity from \(range)"
            }
            return "Checked activity"
        case "list_memories":
            return "Read saved memories"
        case "search_evidence":
            if let query = args["query"] as? String, !query.isEmpty {
                return "Searched “\(query)”"
            }
            return "Searched the vault"
        case "get_moment":
            return "Opened a moment"
        case "get_ocr":
            return "Read on-screen text"
        case "get_ax_digest", "get_ax_tree":
            return "Read the interface tree"
        default:
            return "Called \(call.name)"
        }
    }

    public static func collapsed(_ tools: [ChatToolCall], calendar: Calendar = .current) -> String {
        guard let first = tools.first else { return "Looked something up" }
        if tools.count == 1 { return headline(first, calendar: calendar) }
        return "\(headline(first, calendar: calendar)) · \(tools.count - 1) more"
    }

    private static func windowLabel(_ args: [String: Any], calendar: Calendar) -> String? {
        guard let from = int64Value(args["from_ms"]), let to = int64Value(args["to_ms"]) else {
            return nil
        }
        return ChatTimeLabel.range(fromMs: from, toMs: to, calendar: calendar)
    }
}

/// Collapsed label for think / tool work after the answer is in.
public enum ChatWorkSummary {
    /// Prefer the live daemon clock. Otherwise use the user→assistant gap
    /// only when it is long enough to be a real turn, not a same-ms write.
    public static func elapsedMs(fromUserMs: Int64?, toAssistantMs: Int64) -> Int? {
        guard let fromUserMs, fromUserMs > 0, toAssistantMs > fromUserMs else { return nil }
        let delta = toAssistantMs - fromUserMs
        return delta >= 400 ? Int(delta) : nil
    }

    public static func label(thoughts: Int, lookups: Int, elapsedMs: Int?) -> String {
        var bits: [String] = []
        if let elapsedMs, elapsedMs > 0 {
            bits.append("Worked for \(ChatProgress.formatElapsed(elapsedMs))")
        } else if thoughts + lookups > 0 {
            bits.append("Worked")
        }
        if thoughts > 0 {
            bits.append(thoughts == 1 ? "1 thought" : "\(thoughts) thoughts")
        }
        if lookups > 0 {
            bits.append(lookups == 1 ? "1 lookup" : "\(lookups) lookups")
        }
        return bits.isEmpty ? "Worked" : bits.joined(separator: " · ")
    }
}

// MARK: - Transcript assembly

public struct ChatBubble: Equatable, Identifiable, Sendable {
    public let id: String
    public let role: ChatRole
    public let text: String
    /// Think / tool segments in display order. Live turns use event arrival;
    /// reloaded rows reconstruct a ReAct order from the stored columns.
    public let parts: [ChatMessagePart]
    public let isStreaming: Bool
    public let createdAtMs: Int64
    /// Set on the streaming bubble while the turn has nothing to show yet.
    public let progress: ChatProgress?
    /// Whether the turn behind this bubble was stopped part-way.
    public let wasAborted: Bool
    /// How long the agent spent working, when we know. Nil if the turn
    /// had no intermediate work or the clock cannot be recovered.
    public let workElapsedMs: Int?

    public var tools: [ChatToolCall] { ChatMessagePart.tools(in: parts) }

    public var reasoning: [ChatReasoningRound] { ChatMessagePart.reasoning(in: parts) }

    public init(
        id: String,
        role: ChatRole,
        text: String,
        tools: [ChatToolCall] = [],
        isStreaming: Bool = false,
        createdAtMs: Int64,
        progress: ChatProgress? = nil,
        reasoning: [ChatReasoningRound] = [],
        wasAborted: Bool = false,
        parts: [ChatMessagePart]? = nil,
        workElapsedMs: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.parts = parts ?? ChatMessagePart.reconstruct(reasoning: reasoning, tools: tools)
        self.isStreaming = isStreaming
        self.createdAtMs = createdAtMs
        self.progress = progress
        self.wasAborted = wasAborted
        self.workElapsedMs = workElapsedMs
    }

    public var markdownBlocks: [MarkdownBlock] {
        switch role {
        case .user: [.markdown(text)]
        case .assistant: StreamingMarkdown.blocks(from: text)
        // Never markdown: a compaction row is the daemon's own prose and is
        // drawn as a rule, not a message.
        case .compaction: [.markdown(text)]
        }
    }

    /// Whether any lookup behind this answer was shortened to fit.
    public var hasTruncatedEvidence: Bool { tools.contains(where: \.truncated) }
}

public enum ChatTranscript {
    public static func bubbles(
        messages: [ChatMessage],
        streamingText: String = "",
        streamingTools: [ChatToolCall] = [],
        streamingReasoning: [ChatReasoningRound] = [],
        streamingParts: [ChatMessagePart] = [],
        isSending: Bool = false,
        nowMs: Int64 = 0,
        liveCompactions: [ChatCompactionNotice] = [],
        progress: ChatProgress? = nil,
        lastWorkElapsedMs: Int? = nil
    ) -> [ChatBubble] {
        var previousUserMs: Int64?
        var items = messages
            // The row for the turn in flight is already on screen as the
            // streaming bubble; showing the half-written row too would double it.
            .filter { !(isSending && $0.status == "streaming") }
            .map { message -> ChatBubble in
            if message.role == .user {
                previousUserMs = message.createdAtMs
            }
            let elapsed = message.role == .assistant
                ? ChatWorkSummary.elapsedMs(
                    fromUserMs: previousUserMs,
                    toAssistantMs: message.createdAtMs
                )
                : nil
            return ChatBubble(
                id: message.id,
                role: message.role,
                text: message.content,
                tools: message.toolCalls,
                createdAtMs: message.createdAtMs,
                reasoning: message.reasoningRounds,
                wasAborted: message.wasAborted,
                parts: message.parts,
                workElapsedMs: elapsed
            )
        }
        if isSending {
            // Compaction during the turn in progress, before the daemon has
            // written its rows. Shown ahead of the streaming answer, which is
            // where it happened.
            for notice in liveCompactions {
                items.append(
                    ChatBubble(
                        id: "live-\(notice.id)",
                        role: .compaction,
                        text: notice.summary,
                        createdAtMs: nowMs
                    )
                )
            }
            let liveParts = streamingParts.isEmpty
                ? ChatMessagePart.reconstruct(
                    reasoning: streamingReasoning,
                    tools: streamingTools
                )
                : streamingParts
            items.append(
                ChatBubble(
                    id: "streaming",
                    role: .assistant,
                    text: streamingText,
                    tools: streamingTools,
                    isStreaming: true,
                    createdAtMs: nowMs,
                    progress: progress,
                    reasoning: streamingReasoning,
                    parts: liveParts,
                    workElapsedMs: progress?.elapsedMs
                )
            )
        } else if let lastWorkElapsedMs, lastWorkElapsedMs > 0,
                  let index = items.lastIndex(where: { $0.role == .assistant })
        {
            // The just-finished turn's clock is more honest than the
            // user→assistant created_at gap (the assistant row is written
            // when the turn starts).
            let finished = items[index]
            items[index] = ChatBubble(
                id: finished.id,
                role: finished.role,
                text: finished.text,
                isStreaming: false,
                createdAtMs: finished.createdAtMs,
                wasAborted: finished.wasAborted,
                parts: finished.parts,
                workElapsedMs: lastWorkElapsedMs
            )
        }
        return items
    }

    /// Compaction notices recovered from a stored thread.
    ///
    /// The daemon does not persist usage — it is a property of a turn that has
    /// already run — but it does persist compaction rows, so reopening a thread
    /// still shows where the agent stopped being able to see.
    public static func compactions(in messages: [ChatMessage]) -> [ChatCompactionNotice] {
        messages.compactMap { message in
            guard message.role == .compaction else { return nil }
            return ChatCompactionNotice(
                id: message.id,
                strategy: "prune_tool_results",
                fromRound: 0,
                toRound: 0,
                tokensBefore: 0,
                tokensAfter: 0
            )
        }
    }
}

// MARK: - Time labels

public enum ChatTimeLabel {
    public static func dayHeading(
        ms: Int64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }

    public static func listTimestamp(
        ms: Int64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        if calendar.isDate(date, inSameDayAs: now) {
            return clock(ms: ms, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let year = calendar.component(.year, from: date)
        let nowYear = calendar.component(.year, from: now)
        let month = calendar.shortMonthSymbols[max(calendar.component(.month, from: date) - 1, 0)]
        let day = calendar.component(.day, from: date)
        if year == nowYear {
            return "\(month) \(day)"
        }
        return "\(month) \(day), \(year)"
    }

    public static func clock(ms: Int64, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }

    public static func slotRange(
        atMs: Int64,
        slotMinutes: Int = 30,
        calendar: Calendar = .current
    ) -> String {
        let slotMs = Int64(slotMinutes) * 60_000
        guard slotMs > 0 else { return clock(ms: atMs, calendar: calendar) }
        let start = atMs >= 0 ? (atMs / slotMs) * slotMs : atMs
        return range(fromMs: start, toMs: start + slotMs, calendar: calendar)
    }

    public static func range(fromMs: Int64, toMs: Int64, calendar: Calendar = .current) -> String {
        "\(clock(ms: fromMs, calendar: calendar))–\(clock(ms: toMs, calendar: calendar))"
    }
}

// MARK: - JSON helpers

func stringifyJSON(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "{}" }
    if let text = value as? String {
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return text
        }
        return compactJSON(text)
    }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8)
    {
        return text
    }
    return compactJSON(String(describing: value))
}

private func compactJSON(_ text: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: ["value": text], options: [.sortedKeys])
    if let data, let wrapped = String(data: data, encoding: .utf8) {
        return wrapped
    }
    return "{}"
}

func intValue(_ value: Any?) -> Int? {
    switch value {
    case let number as Int: number
    case let number as Int64: Int(clamping: number)
    case let number as NSNumber: number.intValue
    case let text as String: Int(text)
    default: nil
    }
}

func int64Value(_ value: Any?) -> Int64? {
    switch value {
    case let number as Int64: number
    case let number as Int: Int64(number)
    case let number as NSNumber: number.int64Value
    case let text as String: Int64(text)
    default: nil
    }
}

private extension Data {
    func trimmingASCIINewlines() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == 0x0A || self[start] == 0x0D || self[start] == 0x20 {
            start = index(after: start)
        }
        while end > start {
            let previous = index(before: end)
            if self[previous] == 0x0A || self[previous] == 0x0D || self[previous] == 0x20 {
                end = previous
            } else {
                break
            }
        }
        return self[start..<end]
    }
}
