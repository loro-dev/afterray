import XCTest
@testable import AfterRayRecall

final class ChatTranscriptTests: XCTestCase {
    func testBubblesFollowStoredOrderAndAttachToolLog() {
        let messages = [
            ChatMessage(
                id: "u1",
                conversationId: "c1",
                role: .user,
                content: "what broke",
                createdAtMs: 1
            ),
            ChatMessage(
                id: "a1",
                conversationId: "c1",
                role: .assistant,
                content: "the compiler",
                toolLog: #"[{"name":"get_slot_card","args":{"at_ms":50400000},"chars":12}]"#,
                createdAtMs: 2
            ),
        ]
        let bubbles = ChatTranscript.bubbles(messages: messages)
        XCTAssertEqual(bubbles.map(\.role), [.user, .assistant])
        XCTAssertEqual(bubbles[1].tools.map(\.name), ["get_slot_card"])
        XCTAssertEqual(bubbles[1].tools.first?.resultChars, 12)
        XCTAssertFalse(bubbles[1].isStreaming)
    }

    func testSendingAppendsAStreamingAssistantBubble() {
        let user = ChatMessage(
            id: "u1",
            conversationId: "c1",
            role: .user,
            content: "hi",
            createdAtMs: 1
        )
        let bubbles = ChatTranscript.bubbles(
            messages: [user],
            streamingText: "hel",
            streamingTools: [
                ChatToolCall(id: "t1", name: "list_moments", argsJSON: "{}")
            ],
            streamingReasoning: [
                ChatReasoningRound(round: 1, text: "checking history")
            ],
            isSending: true,
            nowMs: 9
        )
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles[1].id, "streaming")
        XCTAssertEqual(bubbles[1].text, "hel")
        XCTAssertTrue(bubbles[1].isStreaming)
        XCTAssertEqual(bubbles[1].tools.map(\.name), ["list_moments"])
        XCTAssertEqual(bubbles[1].reasoning.first?.text, "checking history")
    }

    func testStreamingPartsStayInArrivalOrder() {
        let user = ChatMessage(
            id: "u1",
            conversationId: "c1",
            role: .user,
            content: "hi",
            createdAtMs: 1
        )
        let tool = ChatToolCall(id: "t1", name: "get_slot_card", argsJSON: "{}", resultChars: 12)
        let parts: [ChatMessagePart] = [
            .reasoning(id: "r1", round: 1, text: "look it up"),
            .tool(tool),
            .reasoning(id: "r2", round: 2, text: "that is the one"),
        ]
        let bubbles = ChatTranscript.bubbles(
            messages: [user],
            streamingText: "You did",
            streamingParts: parts,
            isSending: true,
            nowMs: 9
        )
        XCTAssertEqual(bubbles[1].parts.count, 3)
        XCTAssertEqual(bubbles[1].parts.map(\.id), ["r1", "t1", "r2"])
        XCTAssertEqual(bubbles[1].reasoning.map(\.text), ["look it up", "that is the one"])
        XCTAssertEqual(bubbles[1].tools.map(\.name), ["get_slot_card"])
    }

    func testStoredHistoryReconstructsTypicalReactOrder() {
        let message = ChatMessage(
            id: "a1",
            conversationId: "c1",
            role: .assistant,
            content: "the compiler",
            toolLog: #"[{"name":"get_slot_card","args":{"at_ms":1},"chars":12}]"#,
            createdAtMs: 2,
            reasoning: #"[{"round":1,"text":"check the card"},{"round":2,"text":"that is the error"}]"#
        )
        let bubbles = ChatTranscript.bubbles(messages: [message])
        XCTAssertEqual(bubbles[0].parts.count, 3, "two thoughts and one tool should interleave")
        guard case .reasoning(_, 1, "check the card") = bubbles[0].parts[0],
              case .tool(let tool) = bubbles[0].parts[1],
              case .reasoning(_, 2, "that is the error") = bubbles[0].parts[2]
        else {
            return XCTFail("expected think → tool → think, got \(bubbles[0].parts)")
        }
        XCTAssertEqual(tool.name, "get_slot_card")
    }

    func testStoredHistoryLeavesLeftoverToolsAfterTheLastThought() {
        let message = ChatMessage(
            id: "a1",
            conversationId: "c1",
            role: .assistant,
            content: "done",
            toolLog: #"[{"name":"get_slot_card","args":{}},{"name":"get_transcript","args":{}}]"#,
            createdAtMs: 2,
            reasoning: #"[{"round":1,"text":"one look"}]"#
        )
        let parts = ChatTranscript.bubbles(messages: [message])[0].parts
        XCTAssertEqual(parts.count, 3)
        guard case .reasoning = parts[0],
              case .tool(let first) = parts[1],
              case .tool(let second) = parts[2]
        else {
            return XCTFail("one thought plus two tools reconstructs as thought then both tools: \(parts)")
        }
        XCTAssertEqual(first.name, "get_slot_card")
        XCTAssertEqual(second.name, "get_transcript")
    }

    func testFinishedAssistantGetsWorkElapsedFromUserGap() {
        let messages = [
            ChatMessage(
                id: "u1",
                conversationId: "c1",
                role: .user,
                content: "what",
                createdAtMs: 1_000
            ),
            ChatMessage(
                id: "a1",
                conversationId: "c1",
                role: .assistant,
                content: "that",
                toolLog: #"[{"name":"get_slot_card","args":{}}]"#,
                createdAtMs: 13_500,
                reasoning: #"[{"round":1,"text":"look"}]"#
            ),
        ]
        let bubble = ChatTranscript.bubbles(messages: messages)[1]
        XCTAssertEqual(bubble.workElapsedMs, 12_500)
        XCTAssertEqual(
            ChatWorkSummary.label(thoughts: 1, lookups: 1, elapsedMs: bubble.workElapsedMs),
            "Worked for 13s · 1 thought · 1 lookup"
        )
    }

    func testLiveElapsedOverridesCreatedAtGap() {
        let messages = [
            ChatMessage(
                id: "u1",
                conversationId: "c1",
                role: .user,
                content: "what",
                createdAtMs: 1_000
            ),
            ChatMessage(
                id: "a1",
                conversationId: "c1",
                role: .assistant,
                content: "that",
                toolLog: #"[{"name":"list_moments","args":{}}]"#,
                createdAtMs: 1_100
            ),
        ]
        let bubble = ChatTranscript.bubbles(
            messages: messages,
            lastWorkElapsedMs: 8_400
        )[1]
        XCTAssertEqual(bubble.workElapsedMs, 8_400)
        XCTAssertEqual(
            ChatWorkSummary.label(thoughts: 0, lookups: 1, elapsedMs: 8_400),
            "Worked for 8.4s · 1 lookup"
        )
    }

    func testTinyCreatedAtGapIsNotADuration() {
        let messages = [
            ChatMessage(id: "u1", conversationId: "c1", role: .user, content: "q", createdAtMs: 10),
            ChatMessage(id: "a1", conversationId: "c1", role: .assistant, content: "a", createdAtMs: 20),
        ]
        XCTAssertNil(ChatTranscript.bubbles(messages: messages)[1].workElapsedMs)
    }

    func testConversationsGroupByLocalDayNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let today = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)
        let yesterday = today - 86_400_000
        let older = today - 10 * 86_400_000
        let conversations = [
            ChatConversation(id: "old", title: "Older", createdAtMs: older + 3_600_000, updatedAtMs: older, messageCount: 1),
            ChatConversation(id: "t2", title: "Later today", createdAtMs: today + 8_000_000, updatedAtMs: today, messageCount: 1),
            ChatConversation(id: "y", title: "Yesterday", createdAtMs: yesterday + 1_000, updatedAtMs: yesterday, messageCount: 1),
            ChatConversation(id: "t1", title: "Earlier today", createdAtMs: today + 1_000, updatedAtMs: today, messageCount: 1),
        ]
        let groups = ChatConversationGrouping.days(conversations, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.label).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].conversations.map(\.id), ["t2", "t1"])
        XCTAssertEqual(groups[1].conversations.map(\.id), ["y"])
        XCTAssertEqual(groups[2].conversations.map(\.id), ["old"])
    }

    func testChatModelCatalogListsEveryLlmPackAndOllamaRow() {
        let packs = [
            ModelPack(
                id: "llm_qwen35_4b_mlx4",
                name: "Qwen 3.5 4B",
                capability: "llm_vlm",
                path: "/tmp/q",
                present: true,
                bytes: 1,
                required: true
            ),
            ModelPack(
                id: "embed",
                name: "Embed",
                capability: "embed",
                path: "/tmp/e",
                present: true,
                bytes: 1,
                required: false
            ),
        ]
        let ollama = (0..<30).map { LlmRemoteModel(id: "m\($0)", name: "model-\($0)") }
        let settings = AppSettings(
            dataDir: "/tmp",
            modelDir: "/tmp",
            recordAudio: false,
            captureIntervalSeconds: 10,
            llmProvider: .ollama,
            llmModel: "m7"
        )
        let catalog = ChatModelChoice.catalog(packs: packs, ollamaModels: ollama, settings: settings)
        XCTAssertEqual(catalog.models.filter { $0.group == "Built-in" }.count, 1)
        XCTAssertEqual(catalog.models.filter { $0.group == "Ollama" }.count, 30)
        XCTAssertEqual(catalog.selectedID, "ollama:m7")
    }

    func testConversationSearchFiltersByTitleAndKeepsDayGroups() {
        let conversations = [
            ChatConversation(id: "a", title: "Flock release bugs", createdAtMs: 2_000, updatedAtMs: 2_000, messageCount: 1),
            ChatConversation(id: "b", title: "Yesterday's meeting", createdAtMs: 1_000, updatedAtMs: 1_000, messageCount: 1),
            ChatConversation(id: "c", title: "flock follow-up", createdAtMs: 3_000, updatedAtMs: 3_000, messageCount: 1),
        ]
        XCTAssertEqual(
            ChatConversationGrouping.matching(conversations, query: "  FLOCK ").map(\.id),
            ["a", "c"]
        )
        XCTAssertEqual(ChatConversationGrouping.matching(conversations, query: "   ").map(\.id), ["a", "b", "c"])
        XCTAssertTrue(ChatConversationGrouping.matching(conversations, query: "zzz").isEmpty)
    }

    func testUnknownRoleDecodesAsAssistant() throws {
        let json = #"{"id":"m1","conversation_id":"c1","role":"system","content":"x","created_at_ms":1}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.role, .assistant)
    }

    func testToolSummaryUsesSlotRangeInFixedCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let call = ChatToolCall(
            id: "t",
            name: "get_slot_card",
            argsJSON: #"{"at_ms":50400000}"#,
            resultChars: 2480
        )
        XCTAssertEqual(
            ChatToolSummary.headline(call, calendar: calendar),
            "Looked up 14:00–14:30"
        )
        XCTAssertEqual(
            ChatToolSummary.collapsed([
                call,
                ChatToolCall(id: "t2", name: "get_transcript", argsJSON: "{}"),
            ], calendar: calendar),
            "Looked up 14:00–14:30 · 1 more"
        )
    }

    func testTranscriptRangeSummary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let call = ChatToolCall(
            id: "t",
            name: "get_transcript",
            argsJSON: #"{"from_ms":50400000,"to_ms":52200000}"#
        )
        XCTAssertEqual(
            ChatToolSummary.headline(call, calendar: calendar),
            "Read the transcript from 14:00–14:30"
        )
    }

    func testListTimestampTodayAndYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let todayMs = Int64(1_000_000 * 1_000)
        let yesterdayMs = todayMs - 86_400_000
        XCTAssertEqual(
            ChatTimeLabel.listTimestamp(ms: todayMs, now: now, calendar: calendar),
            ChatTimeLabel.clock(ms: todayMs, calendar: calendar)
        )
        XCTAssertEqual(
            ChatTimeLabel.listTimestamp(ms: yesterdayMs, now: now, calendar: calendar),
            "Yesterday"
        )
    }
}

final class ChatStreamReducerTests: XCTestCase {
    func testReducerAccumulatesTokensAndClosesTools() {
        var state = ChatStreamState()
        ChatStreamReducer.apply(.toolCall(name: "get_slot_card", argsJSON: #"{"at_ms":1}"#), to: &state)
        ChatStreamReducer.apply(.toolResult(name: "get_slot_card", chars: 20), to: &state)
        ChatStreamReducer.apply(.token(text: "You "), to: &state)
        ChatStreamReducer.apply(.token(text: "did"), to: &state)
        ChatStreamReducer.apply(
            .done(messageId: "m9", conversationId: "c9"),
            to: &state
        )
        XCTAssertEqual(state.text, "You did")
        XCTAssertEqual(state.tools.first?.resultChars, 20)
        XCTAssertEqual(state.conversationId, "c9")
        XCTAssertEqual(state.messageId, "m9")
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.shouldFallbackToSend)
    }

    func testBareErrorWithoutWorkFallsBackToSend() {
        var state = ChatStreamState()
        ChatStreamReducer.apply(.error(message: "unknown request"), to: &state)
        XCTAssertTrue(state.shouldFallbackToSend)
    }

    func testReducerKeepsThinkToolThinkAsSeparateParts() {
        var state = ChatStreamState()
        ChatStreamReducer.apply(.reasoning(text: "plan ", round: 1), to: &state)
        ChatStreamReducer.apply(.reasoning(text: "lookup", round: 1), to: &state)
        ChatStreamReducer.apply(.toolCall(name: "get_slot_card", argsJSON: #"{"at_ms":1}"#), to: &state)
        ChatStreamReducer.apply(.toolResult(name: "get_slot_card", chars: 20), to: &state)
        ChatStreamReducer.apply(.reasoning(text: "found it", round: 2), to: &state)
        ChatStreamReducer.apply(.token(text: "You "), to: &state)
        ChatStreamReducer.apply(.token(text: "did"), to: &state)

        XCTAssertEqual(state.parts.count, 3, "think → tool → think must stay three stretches")
        XCTAssertEqual(state.text, "You did")
        guard case .reasoning(_, 1, let first) = state.parts[0] else {
            return XCTFail("first part should be round-1 reasoning, got \(state.parts[0])")
        }
        XCTAssertEqual(first, "plan lookup")
        guard case .tool(let tool) = state.parts[1] else {
            return XCTFail("second part should be the tool, got \(state.parts[1])")
        }
        XCTAssertEqual(tool.name, "get_slot_card")
        XCTAssertEqual(tool.resultChars, 20)
        guard case .reasoning(_, 2, let second) = state.parts[2] else {
            return XCTFail("third part should be round-2 reasoning, got \(state.parts[2])")
        }
        XCTAssertEqual(second, "found it")
        XCTAssertEqual(state.reasoning.map(\.round), [1, 2])
        XCTAssertEqual(state.tools.map(\.name), ["get_slot_card"])
    }

    func testSameRoundReasoningAfterAToolStartsANewPart() {
        var state = ChatStreamState()
        ChatStreamReducer.apply(.reasoning(text: "before", round: 1), to: &state)
        ChatStreamReducer.apply(.toolCall(name: "list_moments", argsJSON: "{}"), to: &state)
        ChatStreamReducer.apply(.reasoning(text: "after", round: 1), to: &state)

        XCTAssertEqual(state.parts.count, 3)
        guard case .reasoning(_, 1, "before") = state.parts[0],
              case .tool = state.parts[1],
              case .reasoning(_, 1, "after") = state.parts[2]
        else {
            return XCTFail("same-round thought after a tool is a new segment: \(state.parts)")
        }
    }
}
