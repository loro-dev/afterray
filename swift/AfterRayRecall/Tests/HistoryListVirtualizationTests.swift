import XCTest
@testable import AfterRayRecall

final class HistoryListVirtualizationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let dayMs: Int64 = 86_400_000

    func testDayCountUsesTheVaultTotalAndHidesWhenUnknown() {
        XCTAssertEqual(HistoryDayCount.label(totalDays: 1), "1 day")
        XCTAssertEqual(HistoryDayCount.label(totalDays: 8), "8 days")
        XCTAssertEqual(HistoryDayCount.label(totalDays: 3), "3 days")
        XCTAssertEqual(HistoryDayCount.label(totalDays: nil), "")
        XCTAssertEqual(HistoryDayCount.label(totalDays: 0), "")
    }

    func testSummaryHistoryPageDecodesVaultTotalWithoutRequiringIt() throws {
        let withTotal = """
            {"days":[],"has_more":true,"total_days":42}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SummaryHistoryPage.self, from: withTotal)
        XCTAssertEqual(decoded.totalDays, 42)
        XCTAssertTrue(decoded.hasMore)

        let withoutTotal = """
            {"days":[],"has_more":false}
            """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(SummaryHistoryPage.self, from: withoutTotal)
        XCTAssertNil(legacy.totalDays)
        XCTAssertFalse(legacy.hasMore)
    }

    func testFlattenPutsHeadingThenNewestSlotsFirst() {
        let day = DaySummary(
            day: "1970-01-02",
            dayStartMs: dayMs,
            dayEndMs: dayMs * 2,
            slots: [
                slot(start: dayMs, title: "morning"),
                slot(start: dayMs + DaySummaryLayout.slotDurationMs, title: "noon"),
            ]
        )
        let items = HistoryListItems.build(
            summaries: [day],
            nowMs: dayMs + 3_600_000,
            expandedSlotStarts: [],
            hasMore: true
        )
        XCTAssertEqual(items.count, 4)
        guard case let .heading(_, label, isToday) = items[0] else {
            return XCTFail("expected heading")
        }
        XCTAssertTrue(label.hasPrefix("Today"), label)
        XCTAssertTrue(isToday)
        guard case let .slot(first, _) = items[1], case let .slot(second, _) = items[2] else {
            return XCTFail("expected slots")
        }
        XCTAssertEqual(first.title, "noon")
        XCTAssertEqual(second.title, "morning")
        XCTAssertEqual(items[3], .loadMore)
    }

    func testFlattenOmitsIdleSlots() {
        let day = DaySummary(
            day: "1970-01-01",
            dayStartMs: 0,
            dayEndMs: dayMs,
            slots: [
                slot(start: 0, title: "work"),
                DaySlotSummary(
                    slotStartMs: DaySummaryLayout.slotDurationMs,
                    slotEndMs: DaySummaryLayout.slotDurationMs * 2,
                    state: "skipped_idle",
                    facts: DaySlotFacts(apps: [])
                ),
            ]
        )
        let items = HistoryListItems.build(
            summaries: [day],
            nowMs: dayMs,
            expandedSlotStarts: [],
            hasMore: false
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.id), ["d-0", "s-0"])
    }

    func testEstimateGrowsWhenASlotIsExpanded() {
        let collapsed = HistoryListItem.slot(slot(start: 0, title: "work", bullets: ["a", "b"]), expanded: false)
        let expanded = HistoryListItem.slot(slot(start: 0, title: "work", bullets: ["a", "b"]), expanded: true)
        XCTAssertGreaterThan(
            HistoryRowHeight.estimate(expanded),
            HistoryRowHeight.estimate(collapsed)
        )
    }

    func testHeightCachePrefersTheMeasuredValueAndCanShrink() {
        let cache = HistoryRowHeightCache()
        cache.record(id: "s-1", measured: 140)
        XCTAssertEqual(cache.height(for: "s-1", estimate: 96), 140)
        cache.record(id: "s-1", measured: 80)
        XCTAssertEqual(cache.height(for: "s-1", estimate: 96), 80)
        cache.invalidate("s-1")
        XCTAssertEqual(cache.height(for: "s-1", estimate: 96), 96)
    }

    func testOriginsFoldSpacingIntoTheNextEdge() {
        let origins = HistoryListLayout.origins(heights: [100, 100, 100], spacing: 8)
        XCTAssertEqual(origins, [0, 108, 216, 316])
    }

    func testVisibleRangeCoversTheViewportPlusOverscan() {
        let origins = HistoryListLayout.origins(heights: Array(repeating: 100, count: 10), spacing: 8)
        let range = HistoryListLayout.visibleRange(
            origins: origins,
            offset: 0,
            viewportHeight: 200,
            overscan: 0
        )
        XCTAssertEqual(range, 0..<2)
    }

    func testUnmountedRowsStillContributeToContentHeight() {
        let origins = HistoryListLayout.origins(heights: Array(repeating: 100, count: 5), spacing: 8)
        XCTAssertEqual(origins.last, 532)
        let window = HistoryListLayout.visibleRange(
            origins: origins,
            offset: 0,
            viewportHeight: 200,
            overscan: 0
        )
        XCTAssertLessThan(window.count, 5)
    }

    func testHeightChangeAboveTheFoldMovesTheClipOrigin() {
        XCTAssertEqual(
            HistoryListLayout.offsetDeltaAfterHeightChange(
                rowOrigin: 0,
                viewportOffset: 200,
                heightDelta: 40
            ),
            40
        )
        XCTAssertEqual(
            HistoryListLayout.offsetDeltaAfterHeightChange(
                rowOrigin: 400,
                viewportOffset: 200,
                heightDelta: 40
            ),
            0
        )
    }

    func testPrefetchStartsFiveRowsFromTheLoadedEdge() {
        XCTAssertFalse(HistoryListLayout.shouldPrefetchOlder(visibleLastIndex: 2, itemCount: 20))
        XCTAssertTrue(HistoryListLayout.shouldPrefetchOlder(visibleLastIndex: 16, itemCount: 20))
        XCTAssertTrue(HistoryListLayout.shouldPrefetchOlder(visibleLastIndex: 19, itemCount: 20))
    }

    func testPinningAFarIndexAddsASecondMountedRange() {
        let origins = HistoryListLayout.origins(heights: Array(repeating: 100, count: 10), spacing: 8)
        let ranges = HistoryListLayout.mountedRanges(
            origins: origins,
            offset: 400,
            viewportHeight: 200,
            extraIndices: [0],
            overscan: 0
        )
        XCTAssertEqual(ranges, [0..<1, 3..<6])
    }

    private func slot(start: Int64, title: String, bullets: [String] = ["detail"]) -> DaySlotSummary {
        DaySlotSummary(
            slotStartMs: start,
            slotEndMs: start + DaySummaryLayout.slotDurationMs,
            state: "done",
            facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 60_000)], momentCount: 2),
            title: title,
            bullets: bullets
        )
    }
}
