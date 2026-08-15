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
