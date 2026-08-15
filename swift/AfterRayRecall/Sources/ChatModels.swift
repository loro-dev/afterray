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

public enum ChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant

    public init(parsing raw: String) {
        switch raw.lowercased() {
        case "user": self = .user
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

    public init(
        id: String,
        conversationId: String,
        role: ChatRole,
        content: String,
        toolLog: String? = nil,
        createdAtMs: Int64
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.toolLog = toolLog
        self.createdAtMs = createdAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case toolLog = "tool_log"
        case createdAtMs = "created_at_ms"
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
    }

    public var toolCalls: [ChatToolCall] { ChatToolLog.parse(toolLog) }

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

public enum ChatStreamEvent: Equatable, Sendable {
    case toolCall(name: String, argsJSON: String)
    case toolResult(name: String, chars: Int)
    case token(text: String)
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
    public static func decode(line: Data) throws -> ChatStreamEvent? {
        let trimmed = line.trimmingASCIINewlines()
        if trimmed.isEmpty { return nil }
        let object = try JSONSerialization.jsonObject(with: trimmed)
        guard let root = object as? [String: Any] else {
            throw DaemonClientError.invalidResponse
        }
        if let kind = root["kind"] as? String {
            return try parse(kind: kind, object: root)
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
                return try parse(kind: kind, object: data)
            }
            throw DaemonClientError.invalidResponse
        }
        throw DaemonClientError.invalidResponse
    }

    private static func parse(kind: String, object: [String: Any]) throws -> ChatStreamEvent {
        switch kind {
        case "tool_call":
            let name = object["name"] as? String ?? "tool"
            return .toolCall(name: name, argsJSON: stringifyJSON(object["args"]))
        case "tool_result":
            let name = object["name"] as? String ?? "tool"
            let chars = intValue(object["chars"]) ?? 0
            return .toolResult(name: name, chars: chars)
        case "token":
            return .token(text: object["text"] as? String ?? "")
        case "done":
            let messageId = object["message_id"] as? String ?? ""
            let conversationId = object["conversation_id"] as? String ?? ""
            return .done(messageId: messageId, conversationId: conversationId)
        case "error":
            return .error(message: object["message"] as? String ?? "Chat failed")
        default:
            throw DaemonClientError.invalidResponse
        }
    }
}

public struct ChatStreamState: Equatable, Sendable {
    public var text: String
    public var tools: [ChatToolCall]
    public var conversationId: String?
    public var messageId: String?
    public var error: String?
    public var isFinished: Bool

    public init(
        text: String = "",
        tools: [ChatToolCall] = [],
        conversationId: String? = nil,
        messageId: String? = nil,
        error: String? = nil,
        isFinished: Bool = false
    ) {
        self.text = text
        self.tools = tools
        self.conversationId = conversationId
        self.messageId = messageId
        self.error = error
        self.isFinished = isFinished
    }

    public var receivedWork: Bool {
        !text.isEmpty || !tools.isEmpty
    }

    public var shouldFallbackToSend: Bool {
        isFinished && !receivedWork && error != nil
    }
}

public enum ChatStreamReducer {
    public static func apply(_ event: ChatStreamEvent, to state: inout ChatStreamState) {
        switch event {
        case .toolCall(let name, let argsJSON):
            state.tools.append(
                ChatToolCall(
                    id: "tool-\(state.tools.count)-\(name)",
                    name: name,
                    argsJSON: argsJSON
                )
            )
        case .toolResult(let name, let chars):
            if let index = state.tools.lastIndex(where: { $0.name == name && $0.resultChars == nil }) {
                state.tools[index].resultChars = chars
            } else {
                state.tools.append(
                    ChatToolCall(
                        id: "tool-\(state.tools.count)-\(name)",
                        name: name,
                        argsJSON: "{}",
                        resultChars: chars
                    )
                )
            }
        case .token(let text):
            state.text += text
        case .done(let messageId, let conversationId):
            if !messageId.isEmpty { state.messageId = messageId }
            if !conversationId.isEmpty { state.conversationId = conversationId }
            state.isFinished = true
        case .error(let message):
            state.error = message
            state.isFinished = true
        }
    }
}

// MARK: - Tool calls

public struct ChatToolCall: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var argsJSON: String
    public var resultChars: Int?

    public init(id: String, name: String, argsJSON: String = "{}", resultChars: Int? = nil) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
        self.resultChars = resultChars
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
                resultChars: intValue(item["chars"])
            )
        }
    }

    public static func encode(_ tools: [ChatToolCall]) -> String? {
        guard !tools.isEmpty else { return nil }
        let payload: [[String: Any]] = tools.map { tool in
            var row: [String: Any] = ["name": tool.name, "args": tool.args]
            if let chars = tool.resultChars { row["chars"] = chars }
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

// MARK: - Transcript assembly

public struct ChatBubble: Equatable, Identifiable, Sendable {
    public let id: String
    public let role: ChatRole
    public let text: String
    public let tools: [ChatToolCall]
    public let isStreaming: Bool
    public let createdAtMs: Int64

    public init(
        id: String,
        role: ChatRole,
        text: String,
        tools: [ChatToolCall] = [],
        isStreaming: Bool = false,
        createdAtMs: Int64
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.tools = tools
        self.isStreaming = isStreaming
        self.createdAtMs = createdAtMs
    }

    public var markdownBlocks: [MarkdownBlock] {
        switch role {
        case .user: [.paragraph(text)]
        case .assistant: StreamingMarkdown.blocks(from: text)
        }
    }
}

public enum ChatTranscript {
    public static func bubbles(
        messages: [ChatMessage],
        streamingText: String = "",
        streamingTools: [ChatToolCall] = [],
        isSending: Bool = false,
        nowMs: Int64 = 0
    ) -> [ChatBubble] {
        var items = messages.map { message in
            ChatBubble(
                id: message.id,
                role: message.role,
                text: message.content,
                tools: message.toolCalls,
                createdAtMs: message.createdAtMs
            )
        }
        if isSending {
            items.append(
                ChatBubble(
                    id: "streaming",
                    role: .assistant,
                    text: streamingText,
                    tools: streamingTools,
                    isStreaming: true,
                    createdAtMs: nowMs
                )
            )
        }
        return items
    }
}

// MARK: - Time labels

public enum ChatTimeLabel {
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
