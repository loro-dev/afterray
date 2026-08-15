import XCTest
@testable import AfterRayRecall

final class DaySummaryLayoutTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testSlotStartAlignsToLocalHalfHour() {
        let day = DaySummaryLayout.dayBounds(ms: 1_786_698_000_000, timeZone: shanghai)
        let sixteen = day.start + 16 * 3_600 * 1_000
        let at = sixteen + 17 * 60 * 1_000
        let start = DaySummaryLayout.slotStartMs(atMs: at, timeZone: shanghai)
        XCTAssertEqual(start, sixteen)
        XCTAssertEqual(DaySummaryLayout.timeLabel(slotStartMs: start, timeZone: shanghai), "16:00")
        XCTAssertEqual(DaySummaryLayout.slotStartMs(atMs: start, timeZone: shanghai), start)
        XCTAssertEqual(
            DaySummaryLayout.slotStartMs(atMs: start + 29 * 60 * 1_000, timeZone: shanghai),
            start
        )
        XCTAssertEqual(
            DaySummaryLayout.slotStartMs(atMs: start + DaySummaryLayout.slotDurationMs, timeZone: shanghai),
            start + DaySummaryLayout.slotDurationMs
        )
    }

    func testHighlightFollowsThePlayheadSlot() {
        let slots = [
            slot(start: 1_000, title: "one"),
            slot(start: 1_000 + DaySummaryLayout.slotDurationMs, title: nil),
        ]
        XCTAssertEqual(
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: 1_200, slots: slots),
            1_000
        )
        XCTAssertEqual(
            DaySummaryLayout.highlightedSlotStartMs(
                playheadMs: 1_000 + DaySummaryLayout.slotDurationMs + 8,
                slots: slots
            ),
            1_000 + DaySummaryLayout.slotDurationMs
        )
        XCTAssertNil(DaySummaryLayout.highlightedSlotStartMs(playheadMs: 99, slots: slots))
    }

    func testRowPrefersT2TitleAndFallsBackToFacts() {
        let titled = slot(
            start: 0,
            title: "  GOP header stuck  ",
            apps: [DayAppFact(name: "Xcode", ms: 1_320_000)]
        )
        let factsOnly = slot(
            start: DaySummaryLayout.slotDurationMs,
            title: nil,
            apps: [
                DayAppFact(name: "Xcode", ms: 1_320_000),
                DayAppFact(name: "Safari", ms: 360_000),
            ]
        )
        let utc = TimeZone(secondsFromGMT: 0)!
        let titledText = DaySummaryLayout.rowText(slot: titled, timeZone: utc)
        XCTAssertTrue(titledText.isT2)
        XCTAssertEqual(titledText.primary, "GOP header stuck")

        let factsText = DaySummaryLayout.rowText(slot: factsOnly, timeZone: utc)
        XCTAssertFalse(factsText.isT2)
        XCTAssertEqual(factsText.primary, "Xcode 22m · Safari 6m")
    }

    /// The panel is where a slot card is actually read. Dropping the bullets
    /// left the user with a title and no way to see what the half hour was.
    func testRowCarriesTheWholeSummaryBody() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let card = DaySlotSummary(
            slotStartMs: 0,
            slotEndMs: DaySummaryLayout.slotDurationMs,
            state: "done",
            facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 900_000)], momentCount: 5),
            title: "Chased a GOP header bug",
            bullets: ["  Read the IVF length check  ", "", "Patched the packer"]
        )
        let text = DaySummaryLayout.rowText(slot: card, timeZone: utc)
        XCTAssertEqual(text.detail, ["Read the IVF length check", "Patched the packer"])

        let bare = DaySummaryLayout.rowText(slot: slot(start: 0, title: nil), timeZone: utc)
        XCTAssertTrue(bare.detail.isEmpty)
    }

    func testEmptyFactsHaveAnExplicitLine() {
        XCTAssertEqual(DaySummaryLayout.factLine(apps: []), "Quiet — nothing on screen")
    }

    /// A fallback row shows an app list, which reads exactly like a finished
    /// summary of a shallow half hour. The badge is the only thing separating
    /// "nothing has read this yet" from "this is all there was".
    func testUnsummarisedRowsSaySo() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let pending = DaySummaryLayout.rowText(slot: slot(start: 0, title: nil), timeZone: utc)
        XCTAssertEqual(pending.badge, "Not summarised")

        let summarised = DaySummaryLayout.rowText(
            slot: slot(start: 0, title: "Chased a GOP header bug"),
            timeZone: utc
        )
        XCTAssertNil(summarised.badge, "a summarised row must not be labelled pending")
    }

    /// Waiting its turn, needing attention, and deliberately skipped are three
    /// different things; collapsing them would tell the user to go look at a
    /// model that is working fine.
    func testEachFallbackReasonIsNamedDistinctly() {
        XCTAssertEqual(DaySummaryLayout.fallbackBadge(state: "degraded"), "Not summarised")
        XCTAssertEqual(DaySummaryLayout.fallbackBadge(state: "failed"), "Summary failed")
        XCTAssertEqual(DaySummaryLayout.fallbackBadge(state: "skipped_idle"), "Idle")
        XCTAssertEqual(DaySummaryLayout.fallbackBadge(state: "paused"), "Capture paused")
        XCTAssertNil(DaySummaryLayout.fallbackBadge(state: "no_data"))
    }

    func testTodayHeadingUsesTodayKicker() {
        let now = Int64(1_786_698_000_000)
        let bounds = DaySummaryLayout.dayBounds(ms: now, timeZone: shanghai)
        let today = DaySummaryLayout.dateHeading(
            dayStartMs: bounds.start,
            nowMs: now,
            timeZone: shanghai
        )
        XCTAssertTrue(today.isToday)
        XCTAssertEqual(today.kicker, "TODAY")

        let yesterday = DaySummaryLayout.dateHeading(
            dayStartMs: bounds.start - 86_400_000,
            nowMs: now,
            timeZone: shanghai
        )
        XCTAssertFalse(yesterday.isToday)
        XCTAssertNotEqual(yesterday.kicker, "TODAY")
    }

    func testDaySummaryDecodesRustSnakeCase() throws {
        let json = """
        {
          "day": "2026-08-14",
          "day_start_ms": 10,
          "day_end_ms": 20,
          "slots": [{
            "slot_start_ms": 10,
            "slot_end_ms": 20,
            "state": "degraded",
            "facts": {
              "apps": [{"name": "Xcode", "bundle_identifier": "com.apple.dt.Xcode", "ms": 60000}],
              "moment_count": 4
            }
          }]
        }
        """
        let decoded = try JSONDecoder().decode(DaySummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.day, "2026-08-14")
        XCTAssertEqual(decoded.slots.count, 1)
        XCTAssertEqual(decoded.slots[0].state, "degraded")
        XCTAssertEqual(decoded.slots[0].facts.apps[0].name, "Xcode")
        XCTAssertNil(decoded.slots[0].title)
    }

    private func slot(
        start: Int64,
        title: String?,
        apps: [DayAppFact] = [DayAppFact(name: "Xcode", ms: 60_000)]
    ) -> DaySlotSummary {
        DaySlotSummary(
            slotStartMs: start,
            slotEndMs: start + DaySummaryLayout.slotDurationMs,
            state: title == nil ? "degraded" : "done",
            facts: DaySlotFacts(apps: apps, momentCount: 3),
            title: title
        )
    }
}
