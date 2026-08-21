import Combine
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

    func testSelectLatestMomentRestoresPlayheadToNewestCapture() async {
        let store = RecallStore(daemon: FakeDaemon())
        await store.loadTimeline()
        store.select(playheadMs: 100)

        XCTAssertTrue(store.selectLatestMoment())
        XCTAssertEqual(store.playheadMs, 200)
        XCTAssertEqual(store.selectedMoment?.id, "m2")
    }

    func testHydrateSelectedEvidenceFillsOcrFromMomentGet() async {
        let store = RecallStore(daemon: FakeDaemon())
        await store.loadTimeline()
        XCTAssertNil(store.selectedMoment?.ocrText)

        await store.hydrateSelectedEvidence()
        XCTAssertEqual(store.selectedMoment?.id, "m2")
        XCTAssertEqual(store.selectedMoment?.ocrText, "ocr-m2")
    }

    func testUnchangedPlayheadDoesNotPublish() async {
        let store = RecallStore(daemon: FakeDaemon())
        await store.loadTimeline()

        var publishes = 0
        let token = store.objectWillChange.sink { publishes += 1 }
        XCTAssertTrue(store.selectLatestMoment())
        store.select(playheadMs: store.playheadMs)
        XCTAssertEqual(publishes, 0)
        store.select(playheadMs: 100)
        XCTAssertEqual(publishes, 1)
        _ = token
    }

    func testConnectionFailureIsAVisibleError() async {
        let store = RecallStore(daemon: ConnectionFailingDaemon())

        await store.loadTimeline()

        XCTAssertEqual(
            store.loadState,
            .failed(message: "Could not reach afterrayd: Connection refused")
        )
        XCTAssertTrue(store.moments.isEmpty)
    }

    func testForcedDaySummaryRefreshRecoversAfterTransientConnectionFailure() async {
        let expected = summaryDay("recovered", startingAt: 400)
        let daemon = FlakySummaryDaemon(summary: expected)
        let store = RecallStore(daemon: daemon)

        await store.loadDaySummary(dayMs: expected.dayStartMs, force: true)
        XCTAssertEqual(store.daySummary, .empty)
        XCTAssertTrue(store.summaryHistory.isEmpty)

        await store.loadDaySummary(dayMs: expected.dayStartMs, force: true)
        XCTAssertEqual(store.daySummary, expected)
        XCTAssertEqual(store.summaryHistory, [expected])
        let requestCount = await daemon.daySummaryRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testLoadTimelineRequestsABoundedWarmRangeNotTheFullArchive() async {
        let daemon = RangeCountingDaemon()
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline()

        let counts = await daemon.counts()
        XCTAssertEqual(counts.timelineList, 0)
        XCTAssertEqual(counts.timelineSince, 0)
        XCTAssertEqual(counts.timelineRange, 1)
        XCTAssertEqual(counts.daySummary, 1)
        XCTAssertEqual(store.moments.map(\.id), ["m1", "m2"])
        let events = await daemon.events()
        guard let summaryIndex = events.firstIndex(of: "summary"),
              let rangeFinishIndex = events.firstIndex(of: "range-finish")
        else {
            return XCTFail("expected both summary and range completion events: \(events)")
        }
        XCTAssertLessThan(summaryIndex, rangeFinishIndex)
    }

    func testExplicitTimelineDayDoesNotReuseAnOlderPlayheadDay() async {
        let daemon = RangeCountingDaemon()
        let store = RecallStore(daemon: daemon)
        store.select(playheadMs: 100)
        let requestedMs: Int64 = 1_786_698_000_000

        await store.loadTimeline(containingMs: requestedMs)

        let bounds = TimelineWarmWindow.bounds(containingMs: requestedMs)
        let ranges = await daemon.ranges()
        XCTAssertEqual(ranges, [.init(fromMs: bounds.start, toMs: bounds.end - 1)])
    }

    func testEmptyDayRefreshStaysOnTheBoundedRange() async {
        let daemon = RangeCountingDaemon(moments: [])
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline()
        await store.refreshTimeline()

        let counts = await daemon.counts()
        XCTAssertEqual(counts.timelineList, 0)
        XCTAssertEqual(counts.timelineSince, 0)
        XCTAssertEqual(counts.timelineRange, 2)
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

    func testImageRepositoryUsesPosterDuringScrubAndExactAfterSettle() async throws {
        let daemon = GopArtifactDaemon()
        let repository = RecallImageRepository(daemon: daemon)

        let firstPoster = try await repository.data(artifactID: "gop-poster:segment-1#0")
        let samePoster = try await repository.data(artifactID: "gop-poster:segment-1#0")
        let exact = try await repository.data(artifactID: "gop:segment-1#7")

        XCTAssertEqual(firstPoster, Data("poster".utf8))
        XCTAssertEqual(samePoster, firstPoster)
        XCTAssertEqual(exact, Data("exact-7".utf8))
        let calls = await daemon.gopCalls
        XCTAssertEqual(
            calls,
            [
                .init(segmentID: "segment-1", index: 0, mode: "poster"),
                .init(segmentID: "segment-1", index: 7, mode: "exact"),
            ]
        )
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
                    hasMore: true,
                    totalDays: 4
                ),
                pagedYesterday.dayStartMs: SummaryHistoryPage(
                    days: [older],
                    nextBeforeMs: nil,
                    hasMore: false,
                    totalDays: 4
                ),
            ]
        )
        let store = RecallStore(daemon: daemon)

        await store.loadDaySummary(dayMs: today.dayStartMs, force: true)
        XCTAssertEqual(store.summaryHistory, [today, pagedYesterday])
        XCTAssertTrue(store.summaryHistoryHasMore)
        XCTAssertEqual(store.summaryHistoryTotalDays, 4)

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

    func testExtendOlderMergesTheNextOccupiedDayBeyondTheWarmWindow() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let fourDaysAgo = localDay(offsetBy: -4, from: today)
        let todayMoment = moment("today", at: today.start + 43_200_000)
        let olderMoment = moment("older", at: fourDaysAgo.start + 43_200_000)
        let daemon = MultiDayTimelineDaemon(moments: [olderMoment, todayMoment])
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: todayMoment.capturedAtMs)
        XCTAssertEqual(store.moments.map(\.id), ["today"])

        let extendedOlder = await store.extendTimeline(direction: .older)
        XCTAssertTrue(extendedOlder)
        XCTAssertEqual(store.moments.map(\.id), ["older", "today"])
        store.select(playheadMs: olderMoment.capturedAtMs)
        XCTAssertEqual(store.selectedMoment?.id, "older")
    }

    func testRefreshDoesNotDiscardAnInFlightOlderExtension() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let fourDaysAgo = localDay(offsetBy: -4, from: today)
        let todayMoment = moment("today", at: today.start + 43_200_000)
        let olderMoment = moment("older", at: fourDaysAgo.start + 43_200_000)
        let refreshedToday = RecallMoment(
            id: todayMoment.id,
            sessionId: todayMoment.sessionId,
            capturedAtMs: todayMoment.capturedAtMs,
            imageArtifactId: todayMoment.imageArtifactId,
            applicationName: "Refreshed Today"
        )
        let daemon = MultiDayTimelineDaemon(
            moments: [olderMoment, todayMoment],
            delayedRangeStartMs: fourDaysAgo.start,
            refreshedRangeStartMs: todayMoment.capturedAtMs,
            refreshedMoments: [refreshedToday]
        )
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: todayMoment.capturedAtMs)
        let extending = Task { @MainActor in
            await store.extendTimeline(direction: .older)
        }
        await daemon.waitForDelayedRangeRequest()

        await store.refreshTimeline()
        await daemon.releaseDelayedRange()
        let extended = await extending.value
        XCTAssertTrue(extended)
        XCTAssertEqual(store.moments.map(\.id), ["older", "today"])
        XCTAssertEqual(store.moments.last?.applicationName, "Refreshed Today")
    }

    func testConcurrentOlderWarmRequestsJoinTheSameFetch() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let fourDaysAgo = localDay(offsetBy: -4, from: today)
        let todayMoment = moment("today", at: today.start + 43_200_000)
        let olderMoment = moment("older", at: fourDaysAgo.start + 43_200_000)
        let daemon = MultiDayTimelineDaemon(
            moments: [olderMoment, todayMoment],
            delayedRangeStartMs: fourDaysAgo.start
        )
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: todayMoment.capturedAtMs)
        let first = Task { @MainActor in
            await store.extendTimeline(direction: .older)
        }
        await daemon.waitForDelayedRangeRequest()
        let joined = Task { @MainActor in
            await store.extendTimeline(direction: .older)
        }
        await Task.yield()
        await daemon.releaseDelayedRange()

        let firstResult = await first.value
        let joinedResult = await joined.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(joinedResult)
        XCTAssertEqual(store.moments.map(\.id), ["older", "today"])
        let rangeCount = await daemon.recordedRanges().count
        XCTAssertEqual(rangeCount, 2)
    }

    func testOppositeWarmRequestsSerializeAndKeepCoverageContiguous() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let center = localDay(offsetBy: -8, from: today)
        let olderDay = localDay(offsetBy: -4, from: center)
        let previousDay = localDay(offsetBy: -1, from: center)
        let nextDay = localDay(offsetBy: 1, from: center)
        let daemon = MultiDayTimelineDaemon(
            moments: (-4...4).map { offset in
                let day = localDay(offsetBy: offset, from: center)
                return moment("d\(offset)", at: day.start + 43_200_000)
            },
            delayedRangeStartMs: olderDay.start
        )
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: center.start + 43_200_000)
        let older = Task { @MainActor in
            await store.extendTimeline(
                direction: .older,
                aroundMs: previousDay.start + 43_200_000
            )
        }
        await daemon.waitForDelayedRangeRequest()
        let newer = Task { @MainActor in
            await store.extendTimeline(
                direction: .newer,
                aroundMs: nextDay.start + 43_200_000
            )
        }
        await Task.yield()
        let rangesWhileOlderIsDelayed = await daemon.recordedRanges()
        XCTAssertEqual(
            rangesWhileOlderIsDelayed.count,
            2,
            "the opposite range must wait instead of racing a stale coverage snapshot"
        )

        await daemon.releaseDelayedRange()
        let olderResult = await older.value
        let newerResult = await newer.value
        XCTAssertTrue(olderResult)
        XCTAssertTrue(newerResult)
        let guaranteed = TimelineWarmWindow.guaranteedBounds(
            containingMs: nextDay.start + 43_200_000
        )
        let coverage = try? XCTUnwrap(store.timelineDayCoverage)
        XCTAssertLessThanOrEqual(coverage?.start ?? .max, guaranteed.start)
        XCTAssertGreaterThanOrEqual(coverage?.end ?? .min, guaranteed.end)
        let finalRanges = await daemon.recordedRanges()
        XCTAssertEqual(finalRanges.count, 3)
    }

    func testExtendNewerMergesTheNextOccupiedDay() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let center = localDay(offsetBy: -8, from: today)
        let fourDaysLater = localDay(offsetBy: 4, from: center)
        let centerMoment = moment("center", at: center.start + 43_200_000)
        let newerMoment = moment("newer", at: fourDaysLater.start + 43_200_000)
        let daemon = MultiDayTimelineDaemon(moments: [centerMoment, newerMoment])
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: centerMoment.capturedAtMs)
        XCTAssertEqual(store.moments.map(\.id), ["center"])
        let extendedNewer = await store.extendTimeline(direction: .newer)
        XCTAssertTrue(extendedNewer)
        XCTAssertEqual(store.moments.map(\.id), ["center", "newer"])
    }

    func testExtendOlderSkipsAnEmptyLocalDay() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let fourDaysAgo = localDay(offsetBy: -4, from: today)
        let fiveDaysAgo = localDay(offsetBy: -5, from: today)
        let todayMoment = moment("today", at: today.start + 43_200_000)
        let olderMoment = moment("older", at: fiveDaysAgo.start + 43_200_000)
        let daemon = MultiDayTimelineDaemon(moments: [olderMoment, todayMoment])
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: todayMoment.capturedAtMs)
        let skippedEmpty = await store.extendTimeline(direction: .older)
        XCTAssertTrue(skippedEmpty)
        XCTAssertEqual(store.moments.map(\.id), ["older", "today"])
        let ranges = await daemon.recordedRanges()
        XCTAssertEqual(ranges.count, 3)
        let warm = TimelineWarmWindow.bounds(containingMs: todayMoment.capturedAtMs)
        XCTAssertEqual(ranges[0], .init(fromMs: warm.start, toMs: warm.end - 1))
        XCTAssertEqual(ranges[1], .init(fromMs: fourDaysAgo.start, toMs: fourDaysAgo.end - 1))
        XCTAssertEqual(ranges[2], .init(fromMs: fiveDaysAgo.start, toMs: fiveDaysAgo.end - 1))
    }

    func testWarmWindowLoadsSevenDaysAtomicallyAndReplenishesBeforeGuaranteeIsConsumed() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let center = localDay(offsetBy: -8, from: today)
        let daemon = MultiDayTimelineDaemon(
            moments: (-4...3).map { offset in
                let day = localDay(offsetBy: offset, from: center)
                return moment("d\(offset)", at: day.start + 43_200_000)
            }
        )
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: center.start + 43_200_000)
        XCTAssertEqual(store.moments.map(\.id), ["d-3", "d-2", "d-1", "d0", "d1", "d2", "d3"])
        let initialRanges = await daemon.recordedRanges()
        let warm = TimelineWarmWindow.bounds(containingMs: center.start + 43_200_000)
        XCTAssertEqual(initialRanges, [.init(fromMs: warm.start, toMs: warm.end - 1)])

        let previousDay = localDay(offsetBy: -1, from: center)
        store.select(playheadMs: previousDay.start + 43_200_000)
        await store.prefetchAdjacentTimelineDays()
        XCTAssertEqual(store.moments.map(\.id), ["d-4", "d-3", "d-2", "d-1", "d0", "d1", "d2"])
        await store.prefetchAdjacentTimelineDays()
        let replenishedRanges = await daemon.recordedRanges()
        XCTAssertEqual(replenishedRanges.count, 2)
        XCTAssertEqual(
            replenishedRanges[1],
            .init(
                fromMs: localDay(offsetBy: -4, from: center).start,
                toMs: localDay(offsetBy: -4, from: center).end - 1
            )
        )
    }

    func testNeighbourRefillPublishesOnePreparedSevenDaySnapshot() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let center = localDay(offsetBy: -8, from: today)
        let daemon = MultiDayTimelineDaemon(
            moments: (-4...3).map { offset in
                let day = localDay(offsetBy: offset, from: center)
                return moment("d\(offset)", at: day.start + 43_200_000)
            }
        )
        let store = RecallStore(daemon: daemon)
        let previousDay = localDay(offsetBy: -1, from: center)

        await store.loadTimeline(containingMs: center.start + 43_200_000)
        var publishedIDs: [[String]] = []
        let token = store.$moments.dropFirst().sink { publishedIDs.append($0.map(\.id)) }

        let extended = await store.extendTimeline(
            direction: .older,
            aroundMs: previousDay.start + 43_200_000
        )

        XCTAssertTrue(extended)
        XCTAssertEqual(
            publishedIDs,
            [["d-4", "d-3", "d-2", "d-1", "d0", "d1", "d2"]],
            "merge and far-side eviction must arrive as one timeline publication"
        )
        XCTAssertEqual(
            store.timelineDayCoverage,
            .warmWindow(containingMs: previousDay.start + 43_200_000)
        )
        XCTAssertEqual(store.timelineSpine, TimelineSpine(moments: store.moments))
        _ = token
    }

    func testFastJumpRefillsTwoDayInvariantWithOneBulkPublication() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let center = localDay(offsetBy: -8, from: today)
        let daemon = MultiDayTimelineDaemon(
            moments: (-6...3).map { offset in
                let day = localDay(offsetBy: offset, from: center)
                return moment("d\(offset)", at: day.start + 43_200_000)
            }
        )
        let store = RecallStore(daemon: daemon)
        let fastJumpDay = localDay(offsetBy: -3, from: center)

        await store.loadTimeline(containingMs: center.start + 43_200_000)
        var publications = 0
        let token = store.$moments.dropFirst().sink { _ in publications += 1 }
        let extended = await store.extendTimeline(
            direction: .older,
            aroundMs: fastJumpDay.start + 43_200_000
        )

        let guaranteed = TimelineWarmWindow.guaranteedBounds(
            containingMs: fastJumpDay.start + 43_200_000
        )
        let coverage = try? XCTUnwrap(store.timelineDayCoverage)
        XCTAssertTrue(extended)
        XCTAssertEqual(publications, 1)
        XCTAssertLessThanOrEqual(coverage?.start ?? .max, guaranteed.start)
        XCTAssertGreaterThanOrEqual(coverage?.end ?? .min, guaranteed.end)
        let ranges = await daemon.recordedRanges()
        XCTAssertEqual(ranges.count, 2, "all missing warm days should share one range request")
        XCTAssertEqual(ranges[1].fromMs, TimelineWarmWindow.bounds(
            containingMs: fastJumpDay.start + 43_200_000
        ).start)
        _ = token
    }

    func testLoadedWindowEvictsTheFarSide() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        var cursor = today.start
        var captured: [RecallMoment] = []
        for index in 0..<10 {
            captured.append(moment("d\(index)", at: cursor + 43_200_000))
            cursor = DaySummaryLayout.dayBounds(ms: cursor - 1).start
        }
        let daemon = MultiDayTimelineDaemon(moments: captured)
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: captured[0].capturedAtMs)
        for _ in 0..<12 {
            guard let oldest = store.moments.first else { break }
            store.select(playheadMs: oldest.capturedAtMs)
            _ = await store.extendTimeline(direction: .older)
        }
        XCTAssertEqual(store.moments.count, RecallStore.maxLoadedTimelineDays)
        XCTAssertFalse(store.moments.contains(where: { $0.id == "d0" }))
        XCTAssertEqual(store.moments.first?.id, "d9")
    }

    func testEnsureFarDayRecentresTheWindow() async {
        let today = DaySummaryLayout.dayBounds(ms: Int64(Date.now.timeIntervalSince1970 * 1_000))
        let yesterday = DaySummaryLayout.dayBounds(ms: today.start - 1)
        var far = yesterday
        for _ in 0..<5 {
            far = DaySummaryLayout.dayBounds(ms: far.start - 1)
        }
        let daemon = MultiDayTimelineDaemon(moments: [
            moment("far", at: far.start + 43_200_000),
            moment("yesterday", at: yesterday.start + 43_200_000),
            moment("today", at: today.start + 43_200_000),
        ])
        let store = RecallStore(daemon: daemon)

        await store.loadTimeline(containingMs: today.start + 43_200_000)
        await store.ensureTimelineContains(ms: far.start + 43_200_000)
        XCTAssertEqual(store.moments.map(\.id), ["far"])
    }
}

private func moment(_ id: String, at capturedAtMs: Int64) -> RecallMoment {
    RecallMoment(id: id, sessionId: "s1", capturedAtMs: capturedAtMs, imageArtifactId: "a-\(id)")
}

private func localDay(
    offsetBy offset: Int,
    from origin: (start: Int64, end: Int64)
) -> (start: Int64, end: Int64) {
    var day = origin
    if offset < 0 {
        for _ in offset..<0 {
            day = DaySummaryLayout.dayBounds(ms: day.start - 1)
        }
    } else if offset > 0 {
        for _ in 0..<offset {
            day = DaySummaryLayout.dayBounds(ms: day.end)
        }
    }
    return day
}

private func summaryDay(_ day: String, startingAt dayStartMs: Int64) -> DaySummary {
    DaySummary(day: day, dayStartMs: dayStartMs, dayEndMs: dayStartMs + 99, slots: [])
}

private actor MultiDayTimelineDaemon: RecallDaemonServing {
    struct Range: Equatable {
        let fromMs: Int64
        let toMs: Int64
    }

    private let stored: [RecallMoment]
    private let delayedRangeStartMs: Int64?
    private let refreshedRangeStartMs: Int64?
    private let refreshedMoments: [RecallMoment]?
    private var ranges: [Range] = []
    private var delayedRangeStarted = false
    private var delayedRangeWaiter: CheckedContinuation<Void, Never>?
    private var delayedRangeReleaseWaiter: CheckedContinuation<Void, Never>?
    private var delayedRangeWasReleased = false

    init(
        moments: [RecallMoment],
        delayedRangeStartMs: Int64? = nil,
        refreshedRangeStartMs: Int64? = nil,
        refreshedMoments: [RecallMoment]? = nil
    ) {
        stored = moments
        self.delayedRangeStartMs = delayedRangeStartMs
        self.refreshedRangeStartMs = refreshedRangeStartMs
        self.refreshedMoments = refreshedMoments
    }

    func recordedRanges() -> [Range] { ranges }

    func waitForDelayedRangeRequest() async {
        guard delayedRangeStartMs != nil, !delayedRangeStarted else { return }
        await withCheckedContinuation { delayedRangeWaiter = $0 }
    }

    func releaseDelayedRange() {
        if let delayedRangeReleaseWaiter {
            self.delayedRangeReleaseWaiter = nil
            delayedRangeReleaseWaiter.resume()
        } else {
            delayedRangeWasReleased = true
        }
    }

    func sessions() async throws -> [RecallSession] {
        [RecallSession(id: "s1", startedAtMs: stored.map(\.capturedAtMs).min() ?? 0)]
    }

    func timeline() async throws -> [RecallMoment] { stored }

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        stored.filter { $0.capturedAtMs >= sinceMs }
    }

    func timeline(fromMs: Int64, toMs: Int64) async throws -> [RecallMoment] {
        ranges.append(.init(fromMs: fromMs, toMs: toMs))
        if fromMs == delayedRangeStartMs, !delayedRangeStarted {
            delayedRangeStarted = true
            delayedRangeWaiter?.resume()
            delayedRangeWaiter = nil
            if delayedRangeWasReleased {
                delayedRangeWasReleased = false
            } else {
                await withCheckedContinuation { delayedRangeReleaseWaiter = $0 }
            }
        }
        let source = fromMs == refreshedRangeStartMs ? (refreshedMoments ?? stored) : stored
        return source.filter { $0.capturedAtMs >= fromMs && $0.capturedAtMs <= toMs }
    }

    func moments(sessionID _: String) async throws -> [RecallMoment] { stored }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] {
        stored
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func moment(id: String) async throws -> RecallMoment {
        stored.first { $0.id == id } ?? RecallMoment(id: id, sessionId: "s1", capturedAtMs: 0)
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor RangeCountingDaemon: RecallDaemonServing {
    struct Range: Equatable {
        let fromMs: Int64
        let toMs: Int64
    }

    struct Counts: Equatable {
        var timelineList = 0
        var timelineSince = 0
        var timelineRange = 0
        var daySummary = 0
    }

    private var recorded = Counts()
    private var recordedRanges: [Range] = []
    private var recordedEvents: [String] = []
    private let returnedMoments: [RecallMoment]

    init(moments: [RecallMoment] = [
        RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 100, imageArtifactId: "a1"),
        RecallMoment(id: "m2", sessionId: "s1", capturedAtMs: 200, imageArtifactId: "a2"),
    ]) {
        returnedMoments = moments
    }

    func counts() -> Counts { recorded }
    func ranges() -> [Range] { recordedRanges }
    func events() -> [String] { recordedEvents }

    func sessions() async throws -> [RecallSession] {
        [RecallSession(id: "s1", startedAtMs: 100)]
    }

    func timeline() async throws -> [RecallMoment] {
        recorded.timelineList += 1
        return []
    }

    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] {
        recorded.timelineSince += 1
        return []
    }

    func timeline(fromMs: Int64, toMs: Int64) async throws -> [RecallMoment] {
        recorded.timelineRange += 1
        recordedRanges.append(.init(fromMs: fromMs, toMs: toMs))
        recordedEvents.append("range-start")
        try await Task.sleep(for: .milliseconds(20))
        recordedEvents.append("range-finish")
        return returnedMoments
    }

    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func daySummary(dayMs _: Int64) async throws -> DaySummary {
        recorded.daySummary += 1
        recordedEvents.append("summary")
        return summaryDay("today", startingAt: 0)
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
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

    func timeline(fromMs _: Int64, toMs _: Int64) async throws -> [RecallMoment] {
        if shouldDelayNextMomentsRequest {
            shouldDelayNextMomentsRequest = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return storedMoments
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

private actor GopArtifactDaemon: RecallDaemonServing {
    struct Call: Equatable {
        let segmentID: String
        let index: UInt16
        let mode: String
    }

    private(set) var gopCalls: [Call] = []

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/jpeg", bytes: Data())
    }
    func gopFrame(segmentID: String, index: UInt16, mode: String) async throws -> ArtifactPayload {
        gopCalls.append(.init(segmentID: segmentID, index: index, mode: mode))
        let bytes = mode == "poster" ? Data("poster".utf8) : Data("exact-\(index)".utf8)
        return ArtifactPayload(id: segmentID, contentType: "video/av1", bytes: bytes)
    }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor ConnectionFailingDaemon: RecallDaemonServing {
    func sessions() async throws -> [RecallSession] {
        throw DaemonClientError.connection("Connection refused")
    }

    func timeline() async throws -> [RecallMoment] {
        throw DaemonClientError.connection("Connection refused")
    }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] {
        throw DaemonClientError.connection("Connection refused")
    }
    func timeline(fromMs _: Int64, toMs _: Int64) async throws -> [RecallMoment] {
        throw DaemonClientError.connection("Connection refused")
    }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func artifact(id _: String) async throws -> ArtifactPayload {
        throw DaemonClientError.connection("Connection refused")
    }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private actor FlakySummaryDaemon: RecallDaemonServing {
    private let summary: DaySummary
    private var requestCount = 0

    init(summary: DaySummary) {
        self.summary = summary
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }

    func daySummary(dayMs _: Int64) async throws -> DaySummary {
        requestCount += 1
        if requestCount == 1 {
            throw DaemonClientError.connection("Connection refused")
        }
        return summary
    }

    func summaryHistory(beforeMs _: Int64?, limit _: Int) async throws -> SummaryHistoryPage {
        SummaryHistoryPage(days: [], nextBeforeMs: nil, hasMore: false)
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        ArtifactPayload(id: id, contentType: "image/png", bytes: Data())
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}

    func daySummaryRequestCount() -> Int { requestCount }
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

    func timeline(fromMs _: Int64, toMs _: Int64) async throws -> [RecallMoment] {
        try await timeline()
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

    func moment(id: String) async throws -> RecallMoment {
        let base = try await timeline().first { $0.id == id }
            ?? RecallMoment(id: id, sessionId: "s1", capturedAtMs: 0)
        return RecallMoment(
            id: base.id,
            sessionId: base.sessionId,
            capturedAtMs: base.capturedAtMs,
            imageArtifactId: base.imageArtifactId,
            ocrText: "ocr-\(id)"
        )
    }

    func setFavorite(momentID: String, favorite: Bool) async throws {
        favoriteCalls.append(.init(momentID: momentID, favorite: favorite))
    }
}
