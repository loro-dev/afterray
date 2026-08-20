import XCTest
@testable import AfterRayRecall

/// Scrubbing the timeline republishes `playheadMs` on every frame. The panel
/// hosts an eager list, so anything that makes it differ frame to frame
/// rebuilds every loaded row. These pin the two values that used to.
final class DaySummaryPanelScrubTests: XCTestCase {
    /// A *local* midnight — derived, not hardcoded, so the fixture does not
    /// straddle two days in whatever zone the test runs in.
    private let dayStart = DaySummaryLayout.dayStartMs(atMs: 1_755_648_000_000)

    private func slot(_ index: Int64) -> DaySlotSummary {
        let start = dayStart + index * 1_800_000
        return DaySlotSummary(
            slotStartMs: start,
            slotEndMs: start + 1_800_000,
            state: "summarized",
            facts: DaySlotFacts(apps: [DayAppFact(name: "Xcode", ms: 900_000)]),
            title: "Slot \(index)",
            details: "## H\n- a bullet"
        )
    }

    private func panel(
        playheadMs: Int64,
        nowMs: Int64,
        extraDay: Bool = false
    ) -> DaySummaryPanel {
        var days = [
            DaySummary(
                day: "2025-08-20",
                dayStartMs: dayStart,
                dayEndMs: dayStart + 86_400_000,
                slots: (0..<12).map { slot(Int64($0)) }
            )
        ]
        if extraDay {
            days.append(
                DaySummary(
                    day: "2025-08-19",
                    dayStartMs: dayStart - 86_400_000,
                    dayEndMs: dayStart,
                    slots: [slot(-4)]
                )
            )
        }
        return DaySummaryPanel(
            summaries: days,
            playheadMs: playheadMs,
            nowMs: nowMs,
            hasMore: false,
            isLoadingMore: false,
            followPulse: 0,
            onSelectSlot: { _ in },
            onLoadMore: {}
        )
    }

    /// A drag across one slot is thousands of frames and must not change a
    /// single stored property of the panel.
    func testScrubbingInsideOneSlotChangesNothing() {
        let base = dayStart + 1_800_000
        let first = panel(playheadMs: base + 1, nowMs: base)
        for step in stride(from: Int64(0), to: Int64(1_800_000), by: 60_000) {
            let next = panel(playheadMs: base + step, nowMs: base + step)
            XCTAssertEqual(next.highlightedSlotStart, first.highlightedSlotStart)
            XCTAssertEqual(next.todayStartMs, first.todayStartMs)
        }
    }

    /// The property the whole optimisation rests on: across a scrub, the
    /// drawn body compares equal, so `.equatable()` skips the entire panel
    /// subtree — windowed list, glass chrome, blurred shadow and all.
    ///
    /// `body` is what SwiftUI evaluates, so asserting on the stored inputs
    /// above is not enough; this asserts on `==` itself.
    func testTheDrawnPanelComparesEqualAcrossAScrub() {
        let base = dayStart + 1_800_000
        let first = panel(playheadMs: base + 1, nowMs: base).content
        for step in stride(from: Int64(0), to: Int64(1_800_000), by: 60_000) {
            let next = panel(playheadMs: base + step, nowMs: base + step).content
            XCTAssertEqual(first, next, "panel rebuilt for a playhead that moved within one slot")
        }
    }

    func testTheDrawnPanelIsUnequalOnceTheHighlightMoves() {
        let inSecond = panel(playheadMs: dayStart + 1_800_000 + 5, nowMs: dayStart).content
        let inThird = panel(playheadMs: dayStart + 3_600_000 + 5, nowMs: dayStart).content
        XCTAssertNotEqual(inSecond, inThird, "the highlight moved and the panel must redraw")
    }

    /// Closures are excluded from `==` on purpose; a change to any *data* the
    /// panel draws must still refresh them, which is what bounds staleness.
    func testNewSummariesRefreshThePanel() {
        let base = dayStart + 1_800_000
        let before = panel(playheadMs: base, nowMs: base).content
        let after = panel(playheadMs: base, nowMs: base, extraDay: true).content
        XCTAssertNotEqual(before, after)
    }

    func testCrossingASlotBoundaryDoesChangeTheHighlight() {
        let inSecond = panel(playheadMs: dayStart + 1_800_000 + 5, nowMs: dayStart)
        let inThird = panel(playheadMs: dayStart + 3_600_000 + 5, nowMs: dayStart)
        XCTAssertNotEqual(inSecond.highlightedSlotStart, inThird.highlightedSlotStart)
        XCTAssertEqual(inSecond.highlightedSlotStart, dayStart + 1_800_000)
    }

    /// `nowMs` was a live wall clock, so it differed on every frame for a
    /// value only ever used to ask "is this day today".
    func testTodayIsQuantizedToTheLocalDay() {
        let midday = DaySummaryLayout.dayStartMs(atMs: dayStart + 43_200_000)
        let evening = DaySummaryLayout.dayStartMs(atMs: dayStart + 79_200_000)
        XCTAssertEqual(midday, evening)
        XCTAssertEqual(
            DaySummaryLayout.localDayKey(ms: midday),
            DaySummaryLayout.localDayKey(ms: dayStart + 43_200_000),
            "quantizing must not shift which local day this is"
        )
        XCTAssertNotEqual(midday, DaySummaryLayout.dayStartMs(atMs: dayStart + 86_400_000 + 60_000))
    }

    /// `.equatable()` on the row is what stops an unrelated update from
    /// re-running ~90 row bodies, so its comparison has to be cheap. Slots
    /// carry a multi-kilobyte `details` string; copies share storage, so this
    /// is a pointer check rather than a character-by-character walk.
    func testComparingRowsIsCheapEnoughToDoNinetyTimesAFrame() {
        let slots = (0..<91).map { _ in slot(3) }
        let copies = slots

        let start = CFAbsoluteTimeGetCurrent()
        var equal = 0
        for _ in 0..<100 {
            for (a, b) in zip(slots, copies) where a == b { equal += 1 }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 100
        XCTAssertEqual(equal, 91 * 100)
        XCTAssertLessThan(ms, 1.0, "row equality took \(ms)ms for 91 slots")
    }
}
