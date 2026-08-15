import XCTest
@testable import AfterRayRecall

@MainActor
final class RecallStoreTests: XCTestCase {
    func testLoadSelectsLatestMomentAndFavoritePersistsThroughDaemon() async {
        let daemon = FakeDaemon()
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline()
        XCTAssertEqual(store.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2"])
        XCTAssertEqual(store.selectedMoment?.id, "m2")

        await store.toggleFavorite()
        XCTAssertEqual(store.selectedMoment?.isFavorite, true)
        let calls = await daemon.favoriteCalls
        XCTAssertEqual(calls, [.init(momentID: "m2", favorite: true)])
    }

    func testConnectionFailureStaysInRecoveringState() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())

        await store.loadTimeline()

        XCTAssertEqual(store.loadState, .ready)
    }

    func testStartupFailureIsNotHiddenByConnectionRetry() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())
        store.reportFailure("afterrayd exited during startup (status 1).\n\nError: key provider: A required entitlement isn't present.")

        await store.loadTimeline()

        XCTAssertEqual(
            store.loadState,
            .failed(
                message: "afterrayd exited during startup (status 1).\n\nError: key provider: A required entitlement isn't present."
            )
        )
    }

    func testImageRepositoryCoalescesConcurrentArtifactLoads() async throws {
        let daemon = CountingArtifactDaemon()
        let repository = RecallImageRepository(daemon: daemon)

        async let first = repository.data(artifactID: "frame-1")
        async let second = repository.data(artifactID: "frame-1")
        let (firstData, secondData) = try await (first, second)

        XCTAssertEqual(firstData, Data("frame".utf8))
        XCTAssertEqual(secondData, firstData)
        let requestCount = await daemon.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testSystemLockClearsTimelineAndArtifactCache() async throws {
        let timelineDaemon = FakeDaemon()
        let store = RecallStore(daemon: timelineDaemon)
        await store.loadTimeline()
        store.clearSensitiveState()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.moments.isEmpty)
        XCTAssertEqual(store.loadState, .ready)

        let artifactDaemon = CountingArtifactDaemon()
        let repository = RecallImageRepository(daemon: artifactDaemon)
        _ = try await repository.data(artifactID: "frame-1")
        await repository.clearSensitiveData()
        _ = try await repository.data(artifactID: "frame-1")
        let requestCount = await artifactDaemon.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testBackgroundRefreshPreservesLatestUserSelection() async {
        let daemon = RefreshingDaemon()
        let store = RecallStore(daemon: daemon)
        await store.loadTimeline()
        XCTAssertEqual(store.selectedMoment?.id, "m2")

        store.select(index: 0)
        await daemon.appendMoment(id: "m3", capturedAtMs: 300)
        await daemon.delayNextMomentsRequest()

        let refresh = Task { @MainActor in
            await store.refreshTimeline(preservingSelection: true)
        }
        try? await Task.sleep(for: .milliseconds(10))
        store.select(index: 1)
        await refresh.value

        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(store.selectedMoment?.id, "m2")
    }

    func testRefreshPreservesPlayheadBetweenMoments() async {
        let daemon = RefreshingDaemon()
        let store = RecallStore(daemon: daemon)
        await store.loadTimeline()

        store.select(playheadMs: 150)
        XCTAssertEqual(store.playheadMs, 150)
        XCTAssertEqual(store.selectedMoment?.id, "m1")

        await daemon.appendMoment(id: "m3", capturedAtMs: 300)
        await store.refreshTimeline(preservingSelection: true)

        XCTAssertEqual(store.playheadMs, 150)
        XCTAssertEqual(store.selectedMoment?.id, "m1")
        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2", "m3"])
    }

    func testSelectingLoadedOlderDayPreservesNewerHistoryAndPagination() async {
        let today = summaryDay("today", startingAt: 400)
        let pagedYesterday = summaryDay("paged-yesterday", startingAt: 300)
        let selectedYesterday = summaryDay("selected-yesterday", startingAt: 300)
        let older = summaryDay("older", startingAt: 200)
        let daemon = SummaryHistoryDaemon(
            selectedDays: [
                today.dayStartMs: today,
                selectedYesterday.dayStartMs: selectedYesterday,
            ],
            pages: [
                today.dayStartMs: SummaryHistoryPage(
                    days: [pagedYesterday],
                    nextBeforeMs: pagedYesterday.dayStartMs,
                    hasMore: true
                ),
                pagedYesterday.dayStartMs: SummaryHistoryPage(
                    days: [older],
                    nextBeforeMs: nil,
                    hasMore: false
                ),
            ]
        )
        let store = RecallStore(daemon: daemon)

        await store.loadDaySummary(dayMs: today.dayStartMs, force: true)
        XCTAssertEqual(store.summaryHistory, [today, pagedYesterday])
        XCTAssertTrue(store.summaryHistoryHasMore)

        await store.loadDaySummary(dayMs: selectedYesterday.dayStartMs, force: true)
        XCTAssertEqual(store.daySummary, selectedYesterday)
        XCTAssertEqual(store.summaryHistory, [today, selectedYesterday])
        XCTAssertTrue(store.summaryHistoryHasMore)
        let requestsAfterSelection = await daemon.recordedSummaryHistoryRequests()
        XCTAssertEqual(requestsAfterSelection, [today.dayStartMs])

        await store.loadOlderSummaryHistory()
        XCTAssertEqual(store.summaryHistory, [today, selectedYesterday, older])
        XCTAssertFalse(store.summaryHistoryHasMore)
        let requestsAfterPagination = await daemon.recordedSummaryHistoryRequests()
        XCTAssertEqual(requestsAfterPagination, [today.dayStartMs, pagedYesterday.dayStartMs])
    }

    func testSelectingUnloadedOlderDayKeepsHistorySortedWhenPaginationFillsGap() async {
        let today = summaryDay("today", startingAt: 400)
        let yesterday = summaryDay("yesterday", startingAt: 300)
        let middle = summaryDay("middle", startingAt: 200)
        let selectedOlder = summaryDay("selected-older", startingAt: 100)
        let daemon = SummaryHistoryDaemon(
            selectedDays: [
                today.dayStartMs: today,
                selectedOlder.dayStartMs: selectedOlder,
            ],
            pages: [
                today.dayStartMs: SummaryHistoryPage(
                    days: [yesterday],
                    nextBeforeMs: yesterday.dayStartMs,
                    hasMore: true
                ),
                yesterday.dayStartMs: SummaryHistoryPage(
                    days: [middle],
                    nextBeforeMs: nil,
                    hasMore: false
                ),
            ]
        )
        let store = RecallStore(daemon: daemon)

        await store.loadDaySummary(dayMs: today.dayStartMs, force: true)
        await store.loadDaySummary(dayMs: selectedOlder.dayStartMs, force: true)
        XCTAssertEqual(store.summaryHistory, [today, yesterday, selectedOlder])

        await store.loadOlderSummaryHistory()
        XCTAssertEqual(store.summaryHistory, [today, yesterday, middle, selectedOlder])
    }
}

private func summaryDay(_ day: String, startingAt dayStartMs: Int64) -> DaySummary {
    DaySummary(day: day, dayStartMs: dayStartMs, dayEndMs: dayStartMs + 99, slots: [])
}

private actor SummaryHistoryDaemon: RecallDaemonServing {
    private let selectedDays: [Int64: DaySummary]
    private let pages: [Int64: SummaryHistoryPage]
    private var summaryHistoryRequests: [Int64?] = []

    init(selectedDays: [Int64: DaySummary], pages: [Int64: SummaryHistoryPage]) {
        self.selectedDays = selectedDays
        self.pages = pages
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func daySummary(dayMs: Int64) async throws -> DaySummary {
        guard let summary = selectedDays[dayMs] else {
            throw DaemonClientError.rejected("No summary for \(dayMs)")
        }
        return summary
    }

    func summaryHistory(beforeMs: Int64?, limit _: Int) async throws -> SummaryHistoryPage {
        summaryHistoryRequests.append(beforeMs)
        guard let beforeMs, let page = pages[beforeMs] else {
            return SummaryHistoryPage(days: [], nextBeforeMs: nil, hasMore: false)
        }
        return page
    }

    func recordedSummaryHistoryRequests() -> [Int64?] {
        summaryHistoryRequests
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor RefreshingDaemon: RecallDaemonServing {
    private var storedMoments = [
        RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 100, imageArtifactId: "a1"),
        RecallMoment(id: "m2", sessionId: "s1", capturedAtMs: 200, imageArtifactId: "a2"),
    ]
    private var shouldDelayNextMomentsRequest = false

    func appendMoment(id: String, capturedAtMs: Int64) {
        storedMoments.append(
            RecallMoment(
                id: id,
                sessionId: "s1",
                capturedAtMs: capturedAtMs,
                imageArtifactId: "artifact-\(id)"
            )
        )
    }

    func delayNextMomentsRequest() {
        shouldDelayNextMomentsRequest = true
    }

    func sessions() async throws -> [RecallSession] {
        [RecallSession(id: "s1", startedAtMs: 100)]
    }

    func timeline() async throws -> [RecallMoment] {
        storedMoments
    }

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments.filter { $0.capturedAtMs >= sinceMs }
    }

    func moments(sessionID _: String) async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments
    }

    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] {
        storedMoments
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/jpeg", bytes: Data())
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor CountingArtifactDaemon: RecallDaemonServing {
    private(set) var requestCount = 0

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func artifact(id: String) async throws -> ArtifactPayload {
        requestCount += 1
        try await Task.sleep(for: .milliseconds(20))
        return ArtifactPayload(
            id: id,
            contentType: "image/jpeg",
            bytes: Data("frame".utf8)
        )
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor ConnectionFailingDaemon: RecallDaemonServing {
    func sessions() async throws -> [RecallSession] {
        throw DaemonClientError.connection("Connection refused")
    }

    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func artifact(id _: String) async throws -> ArtifactPayload {
        throw DaemonClientError.connection("Connection refused")
    }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor FakeDaemon: RecallDaemonServing {
    struct FavoriteCall: Equatable { let momentID: String; let favorite: Bool }
    var favoriteCalls: [FavoriteCall] = []

    func sessions() async throws -> [RecallSession] {
        [
            RecallSession(id: "s1", startedAtMs: 100),
            RecallSession(id: "s2", startedAtMs: 200),
        ]
    }

    func timeline() async throws -> [RecallMoment] {
        [
            RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 100, imageArtifactId: "a1"),
            RecallMoment(id: "m2", sessionId: "s2", capturedAtMs: 200, imageArtifactId: "a2"),
        ]
    }

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        try await timeline().filter { $0.capturedAtMs >= sinceMs }
    }

    func moments(sessionID: String) async throws -> [RecallMoment] {
        try await timeline().filter { $0.sessionId == sessionID }
    }

    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment] {
        try await moments(sessionID: sessionID)
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func setFavorite(momentID: String, favorite: Bool) async throws {
        favoriteCalls.append(.init(momentID: momentID, favorite: favorite))
    }
}
