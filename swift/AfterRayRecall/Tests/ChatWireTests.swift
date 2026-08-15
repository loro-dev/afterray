import Darwin
import XCTest
@testable import AfterRayRecall

final class ChatWireTests: XCTestCase {
    func testChatSendOmitsConversationUntilOneExists() throws {
        let request = WireRequest(type: "chat_send", message: "我今天下午在干嘛")
        let json = try encode(request)
        XCTAssertEqual(json["type"] as? String, "chat_send")
        XCTAssertEqual(json["message"] as? String, "我今天下午在干嘛")
        XCTAssertNil(json["conversation_id"])
        XCTAssertNil(json["question"])
    }

    func testChatStreamAndHistoryAndDeleteMatchPlanFields() throws {
        let stream = try encode(
            WireRequest(type: "chat_stream", conversationID: "c1", message: "and then?")
        )
        XCTAssertEqual(stream["type"] as? String, "chat_stream")
        XCTAssertEqual(stream["conversation_id"] as? String, "c1")
        XCTAssertEqual(stream["message"] as? String, "and then?")

        let history = try encode(WireRequest(type: "chat_history", conversationID: "c1"))
        XCTAssertEqual(history["type"] as? String, "chat_history")
        XCTAssertEqual(history["conversation_id"] as? String, "c1")

        let delete = try encode(WireRequest(type: "chat_delete", conversationID: "c1"))
        XCTAssertEqual(delete["type"] as? String, "chat_delete")

        let list = try encode(WireRequest(type: "chat_list"))
        XCTAssertEqual(list["type"] as? String, "chat_list")
        XCTAssertNil(list["conversation_id"])
    }

    /// The daemon's event set grows; the app and the daemon ship separately.
    /// An unknown `kind` has to be skipped, or every new daemon event turns
    /// into a broken chat window on an app that has not caught up.
    func testUnknownEventKindIsSkippedRatherThanThrown() throws {
        let line = Data(#"{"kind":"steering","messages":["do this instead"]}"#.utf8)
        XCTAssertNil(try ChatStreamEventDecoder.decode(line: line))
    }

    /// The dead-air heartbeat. Without it a thinking model leaves the window
    /// blank for its whole reasoning phase — 131 deltas, measured.
    func testProgressDecodesFromTheWire() throws {
        let event = try ChatStreamEventDecoder.decode(
            line: Data(
                #"{"kind":"progress","phase":"thinking","reasoning_deltas":131,"elapsed_ms":2400,"round":1}"#.utf8
            )
        )
        guard case .progress(let progress)? = event else {
            return XCTFail("expected a progress event, got \(String(describing: event))")
        }
        XCTAssertEqual(progress.phase, .thinking)
        XCTAssertEqual(progress.reasoningDeltas, 131)
        XCTAssertEqual(progress.elapsedMs, 2_400)
        XCTAssertEqual(progress.title, "Thinking")
        XCTAssertEqual(progress.detail, "131 steps · 2.4s")
    }

    /// A phase this build has never heard of must still show something. Blanking
    /// the indicator would put the dead air back.
    func testUnknownProgressPhaseFallsBackRatherThanVanishing() throws {
        let event = try ChatStreamEventDecoder.decode(
            line: Data(#"{"kind":"progress","phase":"summarising","elapsed_ms":900}"#.utf8)
        )
        guard case .progress(let progress)? = event else {
            return XCTFail("expected a progress event")
        }
        XCTAssertEqual(progress.phase, .generating)
        XCTAssertEqual(progress.title, "Working")
        XCTAssertEqual(progress.detail, "0.9s")
    }

    /// The general case, which matters more than thinking: nothing is streaming
    /// at all, as during a cold model load.
    func testProgressWithoutReasoningShowsElapsedOnly() {
        let waiting = ChatProgress(phase: .generating, reasoningDeltas: 0, elapsedMs: 12_700, round: 1)
        XCTAssertEqual(waiting.detail, "13s")
    }

    /// Once there is something to read, the indicator has to get out of the way
    /// — two "it is working" signals at once is worse than one.
    func testProgressClearsAsSoonAsThereIsSomethingToShow() {
        var state = ChatStreamState()
        let progress = ChatProgress(phase: .thinking, reasoningDeltas: 4, elapsedMs: 800, round: 1)

        ChatStreamReducer.apply(.progress(progress), to: &state)
        XCTAssertNotNil(state.progress)
        ChatStreamReducer.apply(.token(text: "OK"), to: &state)
        XCTAssertNil(state.progress)

        ChatStreamReducer.apply(.progress(progress), to: &state)
        ChatStreamReducer.apply(.toolCall(name: "get_now", argsJSON: "{}"), to: &state)
        XCTAssertNil(state.progress, "the tool row takes over as the sign of work")

        ChatStreamReducer.apply(.progress(progress), to: &state)
        ChatStreamReducer.apply(.done(messageId: "m", conversationId: "c"), to: &state)
        XCTAssertNil(state.progress)
    }

    func testUsageAndCompactionDecodeFromTheWire() throws {
        let usage = try ChatStreamEventDecoder.decode(
            line: Data(#"{"kind":"usage","prompt_tokens":5120,"window_tokens":16384,"round":2}"#.utf8)
        )
        guard case .usage(let value)? = usage else {
            return XCTFail("expected a usage event, got \(String(describing: usage))")
        }
        XCTAssertEqual(value.promptTokens, 5_120)
        XCTAssertEqual(value.windowTokens, 16_384)
        XCTAssertEqual(value.round, 2)
        XCTAssertEqual(value.fraction, 5_120.0 / 16_384.0, accuracy: 0.0001)
        XCTAssertFalse(value.isTight)
        XCTAssertEqual(value.shortLabel, "5.1k / 16k")

        let compaction = try ChatStreamEventDecoder.decode(
            line: Data(
                #"{"kind":"compaction","strategy":"prune_tool_results","from_round":0,"to_round":2,"tokens_before":14000,"tokens_after":6200}"#.utf8
            )
        )
        guard case .compaction(let notice)? = compaction else {
            return XCTFail("expected a compaction event, got \(String(describing: compaction))")
        }
        XCTAssertEqual(notice.strategy, "prune_tool_results")
        XCTAssertEqual(notice.droppedResults, 3)
        XCTAssertTrue(notice.summary.contains("Dropped 3 earlier lookups"))
        XCTAssertTrue(notice.summary.contains("14k → 6.2k"))
    }

    /// A line from a daemon that predates `truncated`/`dropped` must still
    /// decode, and must not claim a result was shortened when it was not.
    func testToolResultDecodesWithAndWithoutTheNewerFields() throws {
        let old = try ChatStreamEventDecoder.decode(
            line: Data(#"{"kind":"tool_result","name":"get_ocr","chars":12}"#.utf8)
        )
        XCTAssertEqual(old, .toolResult(name: "get_ocr", chars: 12, truncated: false, dropped: 0))

        let new = try ChatStreamEventDecoder.decode(
            line: Data(#"{"kind":"tool_result","name":"get_ocr","chars":8192,"truncated":true,"dropped":1940}"#.utf8)
        )
        XCTAssertEqual(new, .toolResult(name: "get_ocr", chars: 8_192, truncated: true, dropped: 1_940))
    }

    func testReducerCarriesUsageAndDeduplicatesCompaction() {
        var state = ChatStreamState()
        for round in 1...3 {
            ChatStreamReducer.apply(
                .usage(ChatContextUsage(promptTokens: round * 1_000, windowTokens: 16_384, round: round)),
                to: &state
            )
        }
        XCTAssertEqual(state.usage?.round, 3)
        XCTAssertEqual(state.usage?.promptTokens, 3_000)

        // The same pass reported twice replaces rather than stacks, or the
        // thread grows a divider per round for one compaction.
        let notice = ChatCompactionNotice(
            id: "compaction-0-2",
            strategy: "prune_tool_results",
            fromRound: 0,
            toRound: 2,
            tokensBefore: 14_000,
            tokensAfter: 6_200
        )
        ChatStreamReducer.apply(.compaction(notice), to: &state)
        ChatStreamReducer.apply(.compaction(notice), to: &state)
        XCTAssertEqual(state.compactions.count, 1)
    }

    func testToolResultMarksTheCallItBelongsTo() {
        var state = ChatStreamState()
        ChatStreamReducer.apply(.toolCall(name: "get_slot_card", argsJSON: "{}"), to: &state)
        ChatStreamReducer.apply(
            .toolResult(name: "get_slot_card", chars: 8_192, truncated: true, dropped: 1_940),
            to: &state
        )
        XCTAssertEqual(state.tools.count, 1)
        XCTAssertTrue(state.tools[0].truncated)
        XCTAssertEqual(state.tools[0].droppedTokens, 1_940)
    }

    /// A compaction row is not speech. It has to arrive as its own role so the
    /// thread can draw a rule instead of a bubble.
    func testCompactionRowDecodesAsItsOwnRole() throws {
        let json = #"{"id":"x1","conversation_id":"c1","role":"compaction","content":"Dropped 2 earlier lookups","created_at_ms":9}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.role, .compaction)

        let bubbles = ChatTranscript.bubbles(messages: [message])
        XCTAssertEqual(bubbles.map(\.role), [.compaction])
        XCTAssertEqual(ChatTranscript.compactions(in: [message]).count, 1)
    }

    func testConversationDecodesProtocolShape() throws {
        let json = #"{"id":"c1","title":"昨天下午","created_at_ms":10,"updated_at_ms":20,"message_count":4}"#
        let conversation = try JSONDecoder().decode(ChatConversation.self, from: Data(json.utf8))
        XCTAssertEqual(conversation.id, "c1")
        XCTAssertEqual(conversation.title, "昨天下午")
        XCTAssertEqual(conversation.messageCount, 4)
        XCTAssertEqual(conversation.updatedAtMs, 20)
    }

    func testHistoryDecodesBareArrayOrWrappedObject() throws {
        let bare = #"[{"id":"m1","conversation_id":"c1","role":"user","content":"hi","created_at_ms":1}]"#
        XCTAssertEqual(
            try JSONDecoder().decode(ChatHistoryPayload.self, from: Data(bare.utf8)).messages.map(\.id),
            ["m1"]
        )
        let wrapped = #"{"messages":[{"id":"m2","conversation_id":"c1","role":"assistant","content":"yo","created_at_ms":2}]}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ChatHistoryPayload.self, from: Data(wrapped.utf8)).messages.map(\.role),
            [.assistant]
        )
    }

    func testStreamEventDecodesBarePlanLine() throws {
        let line = Data(#"{"kind":"token","text":"你今天下午"}"#.utf8)
        let event = try XCTUnwrap(ChatStreamEventDecoder.decode(line: line))
        XCTAssertEqual(event, .token(text: "你今天下午"))
    }

    func testStreamEventDecodesDaemonEnvelope() throws {
        let line = Data(
            """
            {"protocol_version":\(UnixSocketDaemonClient.protocolVersion),"ok":true,\
            "data":{"kind":"done","message_id":"m1","conversation_id":"c1"}}
            """.utf8
        )
        let event = try XCTUnwrap(ChatStreamEventDecoder.decode(line: line))
        XCTAssertEqual(event, .done(messageId: "m1", conversationId: "c1"))
    }

    func testStreamEventDecodesToolCallAndResult() throws {
        let call = Data(#"{"kind":"tool_call","name":"get_slot_card","args":{"at_ms":42}}"#.utf8)
        XCTAssertEqual(
            try ChatStreamEventDecoder.decode(line: call),
            .toolCall(name: "get_slot_card", argsJSON: #"{"at_ms":42}"#)
        )
        let result = Data(#"{"kind":"tool_result","name":"get_slot_card","chars":2480}"#.utf8)
        XCTAssertEqual(
            try ChatStreamEventDecoder.decode(line: result),
            .toolResult(name: "get_slot_card", chars: 2480)
        )
    }

    func testEnvelopeErrorBecomesStreamError() throws {
        let line = Data(
            """
            {"protocol_version":\(UnixSocketDaemonClient.protocolVersion),"ok":false,\
            "error":"unknown request"}
            """.utf8
        )
        XCTAssertEqual(
            try ChatStreamEventDecoder.decode(line: line),
            .error(message: "unknown request")
        )
    }

    func testChatSendDecodesTheDaemonsNestedConversationShape() throws {
        // Verified against a live daemon on 2026-08-14: a send answers with
        // the whole conversation plus `assistant_message_id`, so the id sits
        // one level down and under a different name than the stream's `done`
        // event uses.
        let json = Data(#"""
        {
          "answer": "you were writing code",
          "assistant_message_id": "01a000ce-67da",
          "user_message_id": "01a000ce-67d8",
          "model_missing": false,
          "conversation": {
            "id": "01a000cd-c5a4",
            "title": "t",
            "created_at_ms": 1786719880612,
            "updated_at_ms": 1786719880613,
            "message_count": 2
          }
        }
        """#.utf8)
        let result = try JSONDecoder().decode(ChatSendResult.self, from: json)
        XCTAssertEqual(result.conversationId, "01a000cd-c5a4")
        XCTAssertEqual(result.messageId, "01a000ce-67da")
    }

    func testSendResultAcceptsConversationId() throws {
        let json = #"{"conversation_id":"c9","message_id":"m9"}"#
        let result = try JSONDecoder().decode(ChatSendResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.conversationId, "c9")
        XCTAssertEqual(result.messageId, "m9")
    }

    func testTransportReadsMultipleNDJSONLines() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let reader = pair[0]
        let writer = pair[1]
        defer {
            Darwin.close(reader)
            Darwin.close(writer)
        }

        let payload = Data(#"{"kind":"token","text":"ab"}"#.utf8) + Data([0x0A])
            + Data(#"{"kind":"done","message_id":"m","conversation_id":"c"}"#.utf8) + Data([0x0A])
        payload.withUnsafeBytes { raw in
            _ = Darwin.write(writer, raw.baseAddress!, payload.count)
        }
        Darwin.shutdown(writer, SHUT_WR)

        var lines: [String] = []
        try UnixLineTransport.readLines(descriptor: reader, isCancelled: { false }) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("token"))
        XCTAssertTrue(lines[1].contains("done"))
    }

    private func encode(_ request: WireRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
