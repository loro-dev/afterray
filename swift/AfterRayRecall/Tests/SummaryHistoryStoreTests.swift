import XCTest
@testable import AfterRayRecall

@MainActor
final class SummaryHistoryStoreTests: XCTestCase {
    func testInitialRequestUsesDaemonNewestBoundary() async {
        let today = day(start: 400)
        let loader = ScriptedSummaryHistoryLoader([
            .page(
                SummaryHistoryPage(
                    days: [today],
                    nextBeforeMs: 300,
                    hasMore: true,
                    totalDays: 4
                )
            )
        ])
        let store = SummaryHistoryStore(loader: loader)

        await store.loadNext()

        let requests = await loader.requests()
        XCTAssertEqual(requests, [.init(beforeMs: nil, limit: 7)])
        XCTAssertEqual(store.state.days, [today])
        XCTAssertEqual(store.state.totalDays, 4)
        XCTAssertEqual(store.state.boundary, .loadable(.before(300)))
    }

    func testPageWithoutVisibleRowsContinuesTheSameLoad() async {
        let idle = day(start: 400, state: "skipped_idle")
        let older = day(start: 300)
        let loader = ScriptedSummaryHistoryLoader([
            .page(
                SummaryHistoryPage(
                    days: [idle],
                    nextBeforeMs: 300,
                    hasMore: true
                )
            ),
            .page(
                SummaryHistoryPage(
                    days: [older],
                    nextBeforeMs: nil,
                    hasMore: false
                )
            ),
        ])
        let store = SummaryHistoryStore(loader: loader)

        await store.loadNext()

        let requests = await loader.requests()
        XCTAssertEqual(
            requests,
            [.init(beforeMs: nil, limit: 7), .init(beforeMs: 300, limit: 7)]
        )
        XCTAssertEqual(store.state.days, [older])
        XCTAssertEqual(store.state.boundary, .end)
    }

    func testFailureKeepsTheCursorRetriable() async {
        let today = day(start: 400)
        let loader = ScriptedSummaryHistoryLoader([
            .failure,
            .page(
                SummaryHistoryPage(
                    days: [today],
                    nextBeforeMs: nil,
                    hasMore: false
                )
            ),
        ])
        let store = SummaryHistoryStore(loader: loader)

        await store.loadNext()
        guard case .failed(.newest, _) = store.state.boundary else {
            return XCTFail("failure must preserve the newest cursor")
        }

        await store.loadNext()

        let requests = await loader.requests()
        XCTAssertEqual(
            requests,
            [.init(beforeMs: nil, limit: 7), .init(beforeMs: nil, limit: 7)]
        )
        XCTAssertEqual(store.state.days, [today])
        XCTAssertEqual(store.state.boundary, .end)
    }

    func testInvalidNextCursorIsFailureRatherThanFalseEnd() async {
        let loader = ScriptedSummaryHistoryLoader([
            .page(
                SummaryHistoryPage(
                    days: [day(start: 400)],
                    nextBeforeMs: nil,
                    hasMore: true
                )
            )
        ])
        let store = SummaryHistoryStore(loader: loader)

        await store.loadNext()

        guard case .failed(.newest, _) = store.state.boundary else {
            return XCTFail("an inconsistent page must remain retryable")
        }
    }

    func testClearRejectsAStaleResponse() async {
        let loader = DelayedSummaryHistoryLoader(
            page: SummaryHistoryPage(
                days: [day(start: 400)],
                nextBeforeMs: nil,
                hasMore: false
            )
        )
        let store = SummaryHistoryStore(loader: loader)
        let load = Task { await store.loadNext() }
        await loader.waitUntilRequested()

        store.clearSensitiveState()
        await load.value

        XCTAssertEqual(store.state, .initial)
        XCTAssertTrue(store.state.days.isEmpty)
    }

    func testLoadingBoundaryDeduplicatesConcurrentCalls() async {
        let loader = DelayedSummaryHistoryLoader(
            page: SummaryHistoryPage(
                days: [day(start: 400)],
                nextBeforeMs: nil,
                hasMore: false
            )
        )
        let store = SummaryHistoryStore(loader: loader)
        let first = Task { await store.loadNext() }
        await loader.waitUntilRequested()

        await store.loadNext()
        await first.value

        let requests = await loader.requests()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.state.boundary, .end)
    }

    func testCancellationCannotLeaveLoadingOrPublishAnIgnoredResponse() async {
        let loader = DelayedSummaryHistoryLoader(
            page: SummaryHistoryPage(
                days: [day(start: 400)],
                nextBeforeMs: nil,
                hasMore: false
            ),
            ignoresCancellation: true
        )
        let store = SummaryHistoryStore(loader: loader)
        let load = Task { await store.loadNext() }
        await loader.waitUntilRequested()

        load.cancel()
        await load.value

        XCTAssertTrue(store.state.days.isEmpty)
        XCTAssertEqual(store.state.boundary, .loadable(.newest))
    }

    func testRefreshAfterSensitiveClearRestartsFromNewest() async {
        let today = day(start: 400)
        let loader = ScriptedSummaryHistoryLoader([
            .page(
                SummaryHistoryPage(
                    days: [today],
                    nextBeforeMs: nil,
                    hasMore: false
                )
            )
        ])
        let store = SummaryHistoryStore(loader: loader)
        store.clearSensitiveState()

        await store.refreshNewest()

        let requests = await loader.requests()
        XCTAssertEqual(requests, [.init(beforeMs: nil, limit: 7)])
        XCTAssertEqual(store.state.days, [today])
        XCTAssertEqual(store.state.boundary, .end)
    }

    func testNewestRefreshPreservesTheTailCursor() async {
        let today = day(start: 400, title: "old")
        let yesterday = day(start: 300)
        let refreshed = day(start: 400, title: "new")
        let loader = ScriptedSummaryHistoryLoader([
            .page(
                SummaryHistoryPage(
                    days: [today],
                    nextBeforeMs: 300,
                    hasMore: true
                )
            ),
            .page(
                SummaryHistoryPage(
                    days: [refreshed],
                    nextBeforeMs: 300,
                    hasMore: true
                )
            ),
            .page(
                SummaryHistoryPage(
                    days: [yesterday],
                    nextBeforeMs: nil,
                    hasMore: false
                )
            ),
        ])
        let store = SummaryHistoryStore(loader: loader)

        await store.loadNext()
        await store.refreshNewest()

        XCTAssertEqual(store.state.days.first?.slots.first?.title, "new")
        XCTAssertEqual(store.state.boundary, .loadable(.before(300)))

        await store.loadNext()

        XCTAssertEqual(store.state.days.map(\.dayStartMs), [400, 300])
        XCTAssertEqual(store.state.boundary, .end)
        let requests = await loader.requests()
        XCTAssertEqual(
            requests,
            [
                .init(beforeMs: nil, limit: 7),
                .init(beforeMs: nil, limit: 7),
                .init(beforeMs: 300, limit: 7),
            ]
        )
    }

    private func day(
        start: Int64,
        state: String = "summarized",
        title: String = "work"
    ) -> DaySummary {
        DaySummary(
            day: "day-\(start)",
            dayStartMs: start,
            dayEndMs: start + 100,
            slots: [
                DaySlotSummary(
                    slotStartMs: start,
                    slotEndMs: start + 100,
                    state: state,
                    facts: DaySlotFacts(apps: []),
                    title: title
                )
            ]
        )
    }
}

private struct SummaryHistoryRequest: Equatable, Sendable {
    let beforeMs: Int64?
    let limit: Int
}

private actor ScriptedSummaryHistoryLoader: SummaryHistoryPageLoading {
    enum Response: Sendable {
        case page(SummaryHistoryPage)
        case failure
    }

    private var responses: [Response]
    private var recordedRequests: [SummaryHistoryRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func summaryHistory(beforeMs: Int64?, limit: Int) async throws -> SummaryHistoryPage {
        recordedRequests.append(.init(beforeMs: beforeMs, limit: limit))
        guard !responses.isEmpty else {
            throw DaemonClientError.rejected("No scripted history response")
        }
        switch responses.removeFirst() {
        case let .page(page): return page
        case .failure: throw DaemonClientError.connection("offline")
        }
    }

    func requests() -> [SummaryHistoryRequest] {
        recordedRequests
    }
}

private actor DelayedSummaryHistoryLoader: SummaryHistoryPageLoading {
    private let page: SummaryHistoryPage
    private let ignoresCancellation: Bool
    private var requestCount = 0

    init(page: SummaryHistoryPage, ignoresCancellation: Bool = false) {
        self.page = page
        self.ignoresCancellation = ignoresCancellation
    }

    func summaryHistory(beforeMs _: Int64?, limit _: Int) async throws -> SummaryHistoryPage {
        requestCount += 1
        if ignoresCancellation {
            try? await Task.sleep(for: .milliseconds(50))
        } else {
            try await Task.sleep(for: .milliseconds(50))
        }
        return page
    }

    func waitUntilRequested() async {
        while requestCount == 0 {
            await Task.yield()
        }
    }

    func requests() -> Int {
        requestCount
    }
}
