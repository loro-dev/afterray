import XCTest
@testable import AfterRayRecall

@MainActor
final class AfterRayChatModelTests: XCTestCase {
    func testSendStreamsTokensThenReloadsHistory() async {
        let daemon = ChatDaemon()
        await daemon.seed(
            conversations: [ChatConversation(id: "c1", title: "Old", createdAtMs: 1, updatedAtMs: 2, messageCount: 0)],
            history: [:]
        )
        await daemon.setEvents([
            .toolCall(name: "get_slot_card", argsJSON: #"{"at_ms":1}"#),
            .token(text: "You "),
            .token(text: "coded"),
            .done(messageId: "a1", conversationId: "c1"),
        ])
        await daemon.setHistory("c1", [
            ChatMessage(id: "u1", conversationId: "c1", role: .user, content: "hi", createdAtMs: 1),
            ChatMessage(id: "a1", conversationId: "c1", role: .assistant, content: "You coded", createdAtMs: 2),
        ])

        let model = AfterRayChatModel(daemon: daemon, clock: { 99 })
        model.draft = "  hi  "
        model.send()
        await waitUntil { !model.isSending }

        XCTAssertEqual(model.selectedID, "c1")
        XCTAssertEqual(model.messages.map(\.content), ["hi", "You coded"])
        XCTAssertEqual(model.streamText, "")
        XCTAssertFalse(model.isSending)
        let streamed = await daemon.lastStreamedMessage
        XCTAssertEqual(streamed, "hi")
    }

    func testUnknownStreamFallsBackToChatSend() async {
        let daemon = ChatDaemon()
        await daemon.setEvents([.error(message: "unknown request type")])
        await daemon.setSendResult(ChatSendResult(conversationId: "c2", messageId: "a2"))
        await daemon.setHistory("c2", [
            ChatMessage(id: "u", conversationId: "c2", role: .user, content: "hello", createdAtMs: 1),
            ChatMessage(id: "a", conversationId: "c2", role: .assistant, content: "there", createdAtMs: 2),
        ])

        let model = AfterRayChatModel(daemon: daemon, clock: { 1 })
        model.draft = "hello"
        model.send()
        await waitUntil { !model.isSending }

        XCTAssertEqual(model.selectedID, "c2")
        XCTAssertEqual(model.messages.last?.content, "there")
        let sent = await daemon.lastSentMessage
        XCTAssertEqual(sent, "hello")
    }

    func testStopKeepsPartialAssistantText() async {
        let daemon = ChatDaemon()
        await daemon.setEvents([
            .token(text: "partial"),
        ])
        await daemon.setBlockAfterFirstEvent(true)

        let model = AfterRayChatModel(daemon: daemon, clock: { 7 })
        model.draft = "go"
        model.send()
        await waitUntil { model.streamText == "partial" }
        model.stop()
        await waitUntil { !model.isSending }

        XCTAssertEqual(model.messages.last?.role, .assistant)
        XCTAssertEqual(model.messages.last?.content, "partial")
        XCTAssertFalse(model.isSending)
    }

    func testDeleteRemovesConversationAndClearsThread() async {
        let daemon = ChatDaemon()
        await daemon.seed(
            conversations: [ChatConversation(id: "c1", title: "Gone", createdAtMs: 1, updatedAtMs: 1, messageCount: 1)],
            history: [
                "c1": [ChatMessage(id: "m", conversationId: "c1", role: .user, content: "x", createdAtMs: 1)],
            ]
        )
        let model = AfterRayChatModel(daemon: daemon)
        await model.refresh()
        await model.select("c1")
        XCTAssertEqual(model.messages.count, 1)
        await model.deleteConversation("c1")
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testRefreshFailureSurfacesASoftNote() async {
        let daemon = ChatDaemon()
        await daemon.setListShouldFail(true)
        let model = AfterRayChatModel(daemon: daemon)
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.statusMessage, "Chat is wired, but afterrayd is not serving it yet.")
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for chat model")
    }
}

extension AfterRayChatModelTests {
    /// The trap. Occupancy belongs to a turn, not to the app, so it must not
    /// survive a conversation switch — the number looks authoritative enough
    /// that showing the previous thread's would simply be believed.
    func testContextUsageResetsWhenTheConversationChanges() async {
        let daemon = ChatDaemon()
        await daemon.seed(
            conversations: [
                ChatConversation(id: "c1", title: "One", createdAtMs: 1, updatedAtMs: 2, messageCount: 2),
                ChatConversation(id: "c2", title: "Two", createdAtMs: 1, updatedAtMs: 3, messageCount: 0),
            ],
            history: [:]
        )
        await daemon.setEvents([
            .usage(ChatContextUsage(promptTokens: 13_900, windowTokens: 16_384, round: 4)),
            .token(text: "crowded"),
            .done(messageId: "a1", conversationId: "c1"),
        ])
        await daemon.setHistory("c1", [
            ChatMessage(id: "u1", conversationId: "c1", role: .user, content: "hi", createdAtMs: 1),
            ChatMessage(id: "a1", conversationId: "c1", role: .assistant, content: "crowded", createdAtMs: 2),
        ])

        let model = AfterRayChatModel(daemon: daemon, clock: { 99 })
        model.draft = "hi"
        model.send()
        await waitUntil { !model.isSending }
        XCTAssertEqual(model.contextUsage?.promptTokens, 13_900)
        XCTAssertTrue(model.contextUsage?.isTight == true)

        await model.select("c2")
        XCTAssertNil(model.contextUsage, "the previous conversation's pressure leaked across the switch")
        XCTAssertTrue(model.compactionNotices.isEmpty)

        // And starting a new thread clears it too.
        model.startNew()
        XCTAssertNil(model.contextUsage)
    }

    /// Compaction rows are stored, so reopening a thread still shows where the
    /// agent stopped being able to see. Usage is not stored, and is not faked.
    func testCompactionNoticesAreRestoredFromHistory() async {
        let daemon = ChatDaemon()
        await daemon.seed(
            conversations: [
                ChatConversation(id: "c1", title: "One", createdAtMs: 1, updatedAtMs: 2, messageCount: 3)
            ],
            history: [:]
        )
        await daemon.setHistory("c1", [
            ChatMessage(id: "u1", conversationId: "c1", role: .user, content: "everything", createdAtMs: 1),
            ChatMessage(
                id: "x1",
                conversationId: "c1",
                role: .compaction,
                content: "Dropped 3 earlier lookups · 14.0k → 6.2k",
                createdAtMs: 2
            ),
            ChatMessage(id: "a1", conversationId: "c1", role: .assistant, content: "here", createdAtMs: 3),
        ])

        let model = AfterRayChatModel(daemon: daemon, clock: { 1 })
        await model.select("c1")

        XCTAssertEqual(model.compactionNotices.count, 1)
        XCTAssertNil(model.contextUsage, "usage is not persisted and must not be invented")
        XCTAssertEqual(
            model.bubbles.map(\.role),
            [.user, .compaction, .assistant],
            "the compaction row must survive as its own kind of row"
        )
    }

    /// A turn that streams a compaction shows it beside the answer as it
    /// happens, not only after the thread reloads.
    func testLiveCompactionAppearsInTheThreadWhileStreaming() async {
        let daemon = ChatDaemon()
        await daemon.setEvents([
            .compaction(
                ChatCompactionNotice(
                    id: "compaction-0-2",
                    strategy: "prune_tool_results",
                    fromRound: 0,
                    toRound: 2,
                    tokensBefore: 14_000,
                    tokensAfter: 6_200
                )
            ),
            .token(text: "partial"),
        ])
        await daemon.setBlockAfterFirstEvent(true)

        let model = AfterRayChatModel(daemon: daemon, clock: { 1 })
        model.draft = "everything"
        model.send()
        await waitUntil { !model.compactionNotices.isEmpty }

        XCTAssertTrue(model.isSending)
        XCTAssertTrue(
            model.bubbles.contains { $0.role == .compaction },
            "a compaction during the turn has to be visible during the turn"
        )
        model.stop()
        await waitUntil { !model.isSending }
    }
}

private actor ChatDaemon: AfterRayChatServing {
    var conversations: [ChatConversation] = []
    var histories: [String: [ChatMessage]] = [:]
    var events: [ChatStreamEvent] = []
    var sendResult = ChatSendResult(conversationId: "c-new")
    var lastStreamedMessage: String?
    var lastSentMessage: String?
    var listShouldFail = false
    var blockAfterFirstEvent = false

    func seed(conversations: [ChatConversation], history: [String: [ChatMessage]]) {
        self.conversations = conversations
        self.histories = history
    }

    func setEvents(_ events: [ChatStreamEvent]) { self.events = events }
    func setSendResult(_ result: ChatSendResult) { sendResult = result }
    func setHistory(_ id: String, _ messages: [ChatMessage]) { histories[id] = messages }
    func setListShouldFail(_ value: Bool) { listShouldFail = value }
    func setBlockAfterFirstEvent(_ value: Bool) { blockAfterFirstEvent = value }

    func chatList() async throws -> [ChatConversation] {
        if listShouldFail { throw DaemonClientError.rejected("chat is not available") }
        return conversations
    }

    func chatHistory(conversationID: String) async throws -> [ChatMessage] {
        histories[conversationID] ?? []
    }

    func chatDelete(conversationID: String) async throws {
        conversations.removeAll { $0.id == conversationID }
        histories[conversationID] = nil
    }

    func chatSend(conversationID: String?, message: String) async throws -> ChatSendResult {
        lastSentMessage = message
        return ChatSendResult(
            conversationId: conversationID ?? sendResult.conversationId,
            messageId: sendResult.messageId
        )
    }

    nonisolated func chatStream(conversationID _: String?, message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let snapshot = await self.streamSnapshot(message: message)
                for (index, event) in snapshot.events.enumerated() {
                    continuation.yield(event)
                    if snapshot.block, index == 0 {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                continuation.finish()
            }
        }
    }

    private func streamSnapshot(message: String) -> (events: [ChatStreamEvent], block: Bool) {
        lastStreamedMessage = message
        return (events, blockAfterFirstEvent)
    }
}
