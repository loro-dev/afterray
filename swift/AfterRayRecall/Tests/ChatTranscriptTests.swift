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
            isSending: true,
            nowMs: 9
        )
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles[1].id, "streaming")
        XCTAssertEqual(bubbles[1].text, "hel")
        XCTAssertTrue(bubbles[1].isStreaming)
        XCTAssertEqual(bubbles[1].tools.map(\.name), ["list_moments"])
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
}
