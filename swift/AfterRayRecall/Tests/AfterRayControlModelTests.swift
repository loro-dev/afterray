import XCTest
@testable import AfterRayRecall

@MainActor
final class AfterRayControlModelTests: XCTestCase {
    func testToggleUsesDaemonRecordCommandsAndRefreshesStatus() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)

        await model.refreshStatus()
        XCTAssertFalse(model.isRecording)
        let started = await model.toggleRecording()
        XCTAssertTrue(started)
        XCTAssertTrue(model.isRecording)
        let stopped = await model.toggleRecording()
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.isRecording)

        let commands = await daemon.recordCommands
        XCTAssertEqual(commands, ["start", "stop"])
    }

    func testWaitingIsNotRecordingButSessionIsActive() async {
        let daemon = ControlDaemon()
        await daemon.setRecordingState(.waiting)
        let model = AfterRayControlModel(daemon: daemon)
        await model.refreshStatus()
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.isWaitingToRecord)
        XCTAssertTrue(model.isCaptureSessionActive)
    }

    func testSearchTrimsQueryAndReturnsTypedHits() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        model.searchQuery = "  architecture  "

        let jumped = await model.search()

        XCTAssertEqual(model.searchSession?.frames.map(\.momentId), ["m1"])
        // Search hands back the frame to jump to, so the caller never has to
        // dig the newest match out of the session itself.
        XCTAssertEqual(jumped?.momentId, "m1")
        let query = await daemon.lastSearchQuery
        XCTAssertEqual(query, "architecture")
    }

    func testEnsureRecordingStartsOnlyWhenIdle() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)

        let first = await model.ensureRecording()
        let second = await model.ensureRecording()
        XCTAssertTrue(first)
        XCTAssertTrue(second)

        let commands = await daemon.recordCommands
        XCTAssertEqual(commands, ["start"])
    }

    func testSystemLockClearsSearchAndStatus() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        await model.refreshStatus()
        model.searchQuery = "private query"
        await model.search()

        model.clearSensitiveState()

        XCTAssertNil(model.status)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertNil(model.searchSession)
        XCTAssertNil(model.message)
    }

    func testAskTrimsQuestionAndStoresAnswer() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        model.askQuestion = "  我今天做了什么  "

        await model.ask()

        XCTAssertEqual(model.askAnswer?.answer, "You used Safari and Xcode.")
        XCTAssertEqual(model.askAnswer?.citations.map(\.momentId), ["m1"])
        XCTAssertFalse(model.askAnswer?.modelMissing ?? true)
        XCTAssertNil(model.askMessage)
        let question = await daemon.lastAskQuestion
        XCTAssertEqual(question, "我今天做了什么")
    }

    func testAskModelMissingKeepsAnswerForCTA() async {
        let daemon = ControlDaemon()
        await daemon.setModelMissing(true)
        let model = AfterRayControlModel(daemon: daemon)
        model.askQuestion = "what did I do"

        await model.ask()

        XCTAssertEqual(model.askAnswer?.modelMissing, true)
        XCTAssertTrue(model.askAnswer?.answer.contains("Settings") ?? false)
        XCTAssertNil(model.askMessage)
    }

    func testAskErrorSurfacesMessageWithoutBlankingQuestion() async {
        let daemon = ControlDaemon()
        await daemon.setAskShouldFail(true)
        let model = AfterRayControlModel(daemon: daemon)
        model.askQuestion = "hello"

        await model.ask()

        XCTAssertNil(model.askAnswer)
        XCTAssertEqual(model.askMessage, "ask exploded")
        XCTAssertEqual(model.askQuestion, "hello")
    }

    func testSystemLockClearsAskState() async {
        let daemon = ControlDaemon()
        let model = AfterRayControlModel(daemon: daemon)
        model.askQuestion = "secret"
        await model.ask()

        model.clearSensitiveState()

        XCTAssertEqual(model.askQuestion, "")
        XCTAssertNil(model.askAnswer)
        XCTAssertNil(model.askMessage)
        XCTAssertFalse(model.isAsking)
    }
}

private actor ControlDaemon: AfterRayDaemonServing {
    var recordingState: DaemonRecordingState = .idle
    var recordCommands: [String] = []
    var lastSearchQuery: String?
    var lastAskQuestion: String?
    var modelMissing = false
    var askShouldFail = false

    func setModelMissing(_ value: Bool) {
        modelMissing = value
    }

    func setAskShouldFail(_ value: Bool) {
        askShouldFail = value
    }

    func setRecordingState(_ value: DaemonRecordingState) {
        recordingState = value
    }

    func status() async throws -> DaemonStatus {
        DaemonStatus(
            daemonVersion: "0.1.0",
            protocolVersion: 1,
            schemaVersion: 1,
            recordingState: recordingState,
            activeSessionId: recordingState == .idle || recordingState == .failed ? nil : "s1"
        )
    }

    func recordStart() async throws -> RecordStartResult {
        recordCommands.append("start")
        recordingState = .recording
        return RecordStartResult(sessionId: "s1")
    }

    func recordStop(reason _: String?) async throws -> RecordStopResult {
        recordCommands.append("stop")
        recordingState = .idle
        return RecordStopResult(sessionId: "s1")
    }

    func shutdown() async throws -> DaemonShutdownResult {
        DaemonShutdownResult(stopping: true, pid: nil)
    }

    func modelLibrary() async throws -> ModelLibrary {
        ModelLibrary(directory: "/tmp/afterray-models", packs: [])
    }

    func settings() async throws -> AppSettings {
        AppSettings(
            dataDir: "/tmp/afterray-data",
            modelDir: "/tmp/afterray-models",
            recordAudio: true,
            captureIntervalSeconds: 10
        )
    }

    func updateSettings(
        recordAudio: Bool?,
        excludedBundleIds _: [String]?,
        excludedDomains _: [String]?,
        llmProvider: LlmProvider?,
        llmBaseUrl: String?,
        llmModel: String?,
        llmApiKey _: String?,
        storageLimitBytes: UInt64?,
        uiLanguage: String?,
        summaryLanguage: String?
    ) async throws -> AppSettings {
        AppSettings(
            dataDir: "/tmp/afterray-data",
            modelDir: "/tmp/afterray-models",
            recordAudio: recordAudio ?? true,
            captureIntervalSeconds: 10,
            storageLimitBytes: storageLimitBytes ?? AppSettings.defaultStorageLimitBytes,
            llmProvider: llmProvider ?? .mlxLocal,
            llmBaseUrl: llmBaseUrl ?? "",
            llmModel: llmModel ?? "",
            uiLanguage: uiLanguage ?? AppSettings.defaultLanguage,
            summaryLanguage: summaryLanguage ?? AppSettings.defaultLanguage
        )
    }

    func probeLlm(provider _: LlmProvider?, baseUrl _: String?) async throws -> LlmEndpointStatus {
        LlmEndpointStatus(reachable: false)
    }

    func clearHistory(scope _: HistoryScope) async throws -> HistoryClearResult {
        HistoryClearResult(deleted: 0, scope: "today")
    }

    func downloadModels(packID: String?) async throws -> ModelLibrary {
        ModelLibrary(directory: "/tmp/afterray-models", packs: [])
    }

    func jobs() async throws -> [ModelJob] {
        []
    }

    func search(query: String, limit: Int) async throws -> [RecallSearchHit] {
        lastSearchQuery = query
        return [
            RecallSearchHit(
                momentId: "m1",
                sessionId: "s1",
                capturedAtMs: 100,
                source: "ocr",
                text: "Architecture notes",
                score: 1
            )
        ]
    }

    func ask(question: String, fromMs _: Int64?, toMs _: Int64?) async throws -> AskAnswer {
        lastAskQuestion = question
        if askShouldFail {
            throw DaemonClientError.rejected("ask exploded")
        }
        if modelMissing {
            return AskAnswer(
                answer: "The local language model is not installed. Open Settings to download the LLM pack.",
                citations: [],
                modelMissing: true
            )
        }
        return AskAnswer(
            answer: "You used Safari and Xcode.",
            citations: [
                AskCitation(momentId: "m1", capturedAtMs: 100, label: "Safari", excerpt: "inbox")
            ],
            modelMissing: false
        )
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment] { [] }
    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "application/octet-stream", bytes: Data())
    }
    func setFavorite(momentID: String, favorite: Bool) async throws {}
}
