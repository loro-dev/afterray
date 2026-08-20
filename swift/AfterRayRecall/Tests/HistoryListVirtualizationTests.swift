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

    /// `ScrollGeometry.visibleRect.minY` is the distance scrolled from the top
    /// and goes negative only while rubber-banding above it.
    func testOverscrollingAboveTheTopIsNotADownwardOffset() {
        XCTAssertEqual(HistoryListLayout.offset(visibleMinY: 620), 620)
        XCTAssertEqual(HistoryListLayout.offset(visibleMinY: 0), 0)
        XCTAssertEqual(HistoryListLayout.offset(visibleMinY: -42), 0)
    }

    func testPrefetchLeadsTheContentEnd() {
        // 400pt of lead: a flick at the bottom is already loading.
        XCTAssertFalse(
            HistoryLoadMore.isNearBottom(offset: 0, viewportHeight: 460, contentHeight: 4000)
        )
        XCTAssertTrue(
            HistoryLoadMore.isNearBottom(offset: 3200, viewportHeight: 460, contentHeight: 4000)
        )
    }

    /// The "Full details" link must appear exactly when there is something to
    /// expand, without paying for a Markdown parse to find out.
    func testExpandableDetailAgreesWithTheParsedSections() {
        let cases: [DaySlotSummary] = [
            slot(start: 0, title: "work", bullets: ["a"]),
            slot(start: 0, title: "work", bullets: []),
            slot(start: 0, title: "work", bullets: ["   "]),
            DaySlotSummary(
                slotStartMs: 0,
                slotEndMs: 1,
                state: "done",
                facts: DaySlotFacts(apps: []),
                title: "v3",
                details: "## Heading\n- a bullet"
            ),
            DaySlotSummary(
                slotStartMs: 0,
                slotEndMs: 1,
                state: "done",
                facts: DaySlotFacts(apps: []),
                title: "blank v3",
                details: "   \n  "
            ),
        ]
        for slot in cases {
            XCTAssertEqual(
                DaySummaryLayout.hasExpandableDetail(slot: slot),
                !DaySummaryLayout.expandedSections(slot: slot).isEmpty,
                "cheap predicate disagreed with the parser for \(slot.title ?? "?")"
            )
        }
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
