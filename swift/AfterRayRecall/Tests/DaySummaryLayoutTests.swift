import XCTest
@testable import AfterRayRecall

final class DaySummaryLayoutTests: XCTestCase {
    func testV2DescriptionAndThreadsDecodeAndDescriptionIsBounded() throws {
        let description = String(repeating: "界", count: 410)
        let json = """
        {
          "slot_start_ms": 0,
          "slot_end_ms": 600000,
          "state": "done",
          "facts": {"apps": [], "moment_count": 3},
          "title": "完成总结侧栏",
          "description": "\(description)",
          "threads": [{"name":"UI","prose":"展示完整工作线","moment_ids":["m1"]}],
          "decisions": ["默认折叠"],
          "not_captured": ["未执行发布"]
        }
        """
        let slot = try JSONDecoder().decode(DaySlotSummary.self, from: Data(json.utf8))
        XCTAssertEqual(DaySummaryLayout.shortDescription(slot: slot).count, 400)
        XCTAssertEqual(slot.threads?.first?.momentIds, ["m1"])
        XCTAssertEqual(DaySummaryLayout.expandedSections(slot: slot).map(\.heading), ["UI", "Decisions", "Not captured"])
    }

    func testV2ThreadWithoutMomentIdsDecodesAsNoCitations() throws {
        let json = #"""
        {
          "slot_start_ms": 0,
          "slot_end_ms": 1800000,
          "state": "done",
          "facts": {"apps": [], "moment_count": 3},
          "title": "Older v2 card",
          "description": "The model did not cite a frame.",
          "threads": [{"name":"Implementation","prose":"Completed the change."}]
        }
        """#

        let slot = try JSONDecoder().decode(DaySlotSummary.self, from: Data(json.utf8))
        XCTAssertEqual(slot.threads?.first?.momentIds, [])
        XCTAssertEqual(slot.threads?.first?.prose, "Completed the change.")
    }

    func testV1BulletsProvideBoundedDescriptionAndFullExpandedDetails() {
        let slot = DaySlotSummary(
            slotStartMs: 0,
            slotEndMs: 1_800_000,
            state: "done",
            facts: DaySlotFacts(apps: []),
            title: "Legacy",
            bullets: [String(repeating: "a", count: 390), String(repeating: "b", count: 30)]
        )
        XCTAssertEqual(DaySummaryLayout.shortDescription(slot: slot).count, 400)
        XCTAssertEqual(DaySummaryLayout.expandedSections(slot: slot).count, 2)
        XCTAssertNil(DaySummaryLayout.expandedSections(slot: slot).first?.heading)
    }

    func testOriginalV1WirePayloadDecodesWithoutAnyV2Fields() throws {
        let json = #"""
        {
          "slot_start_ms": 1786698000000,
          "slot_end_ms": 1786699800000,
          "state": "done",
          "facts": {
            "apps": [{"name":"Xcode","bundle_identifier":"com.apple.dt.Xcode","ms":900000}],
            "moment_count": 12
          },
          "title": "Legacy summary",
          "bullets": ["First old bullet", "Second old bullet"],
          "category": "coding"
        }
        """#

        let slot = try JSONDecoder().decode(DaySlotSummary.self, from: Data(json.utf8))
        XCTAssertEqual(slot.slotEndMs - slot.slotStartMs, 30 * 60 * 1_000)
        XCTAssertEqual(slot.title, "Legacy summary")
        XCTAssertEqual(slot.bullets, ["First old bullet", "Second old bullet"])
        XCTAssertNil(slot.anchorMomentId)
        XCTAssertNil(slot.description)
        XCTAssertNil(slot.threads)
        XCTAssertEqual(
            DaySummaryLayout.shortDescription(slot: slot),
            "First old bullet Second old bullet"
        )
        XCTAssertEqual(DaySummaryLayout.expandedSections(slot: slot).count, 2)
    }

    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testSlotStartAlignsToLocalTenMinutes() {
        let day = DaySummaryLayout.dayBounds(ms: 1_786_698_000_000, timeZone: shanghai)
        let sixteen = day.start + 16 * 3_600 * 1_000
        let at = sixteen + 17 * 60 * 1_000
        let start = DaySummaryLayout.slotStartMs(atMs: at, timeZone: shanghai)
        XCTAssertEqual(start, sixteen + 10 * 60 * 1_000)
        XCTAssertEqual(DaySummaryLayout.timeLabel(slotStartMs: start, timeZone: shanghai), "16:10")
        XCTAssertEqual(DaySummaryLayout.slotStartMs(atMs: start, timeZone: shanghai), start)
        XCTAssertEqual(
            DaySummaryLayout.slotStartMs(atMs: start + 9 * 60 * 1_000, timeZone: shanghai),
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

    func testRowDefaultsToOneShortDescriptionAndExpansionKeepsWholeBody() {
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
        XCTAssertEqual(text.detail, ["Read the IVF length check Patched the packer"])
        XCTAssertEqual(
            DaySummaryLayout.expandedSections(slot: card).map(\.body),
            ["Read the IVF length check", "Patched the packer"]
        )

        let bare = DaySummaryLayout.rowText(slot: slot(start: 0, title: nil), timeZone: utc)
        XCTAssertTrue(bare.detail.isEmpty)
    }

    /// Presentation order is newest-first, the way every feed the user
    /// lives in orders time; storage stays chronological.
    func testDisplayOrderPutsTheNewestSlotFirst() {
        let slots = [
            slot(start: 0, title: "morning"),
            slot(start: DaySummaryLayout.slotDurationMs * 2, title: "noon"),
            slot(start: DaySummaryLayout.slotDurationMs, title: "late morning"),
        ]
        let ordered = DaySummaryLayout.displayOrder(slots)
        XCTAssertEqual(ordered.map(\.title), ["noon", "late morning", "morning"])
    }

    /// Idle slots exist on the wire so the day is complete, but they add
    /// nothing to read — the panel skips them instead of painting "Idle".
    func testDisplayOrderOmitsIdleSlots() {
        let work = slot(start: 0, title: "morning")
        let idle = DaySlotSummary(
            slotStartMs: DaySummaryLayout.slotDurationMs,
            slotEndMs: DaySummaryLayout.slotDurationMs * 2,
            state: "skipped_idle",
            facts: DaySlotFacts(apps: [], momentCount: 0)
        )
        let later = slot(start: DaySummaryLayout.slotDurationMs * 2, title: "afternoon")
        let ordered = DaySummaryLayout.displayOrder([work, idle, later])
        XCTAssertEqual(ordered.map(\.title), ["afternoon", "morning"])
        XCTAssertFalse(ordered.contains(where: { $0.state == "skipped_idle" }))
        XCTAssertFalse(DaySummaryLayout.isVisibleInPanel(idle))
        XCTAssertNil(
            DaySummaryLayout.highlightedSlotStartMs(
                playheadMs: idle.slotStartMs + 1,
                slots: [work, idle, later]
            ),
            "playhead over idle must not follow a card the panel never drew"
        )
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

    /// Copy is for pasting into notes: chronological, day-headed, bullets
    /// indented — regardless of the newest-first display order. Idle gaps
    /// stay out of the paste the same way they stay out of the panel.
    func testClipboardTextIsChronologicalAndComplete() {
        let day = DaySummary(
            day: "2026-08-15",
            dayStartMs: 0,
            dayEndMs: 86_400_000,
            slots: [
                DaySlotSummary(
                    slotStartMs: DaySummaryLayout.slotDurationMs,
                    slotEndMs: DaySummaryLayout.slotDurationMs * 2,
                    state: "done",
                    facts: DaySlotFacts(apps: []),
                    title: "Later work",
                    bullets: ["shipped the fix"]
                ),
                DaySlotSummary(
                    slotStartMs: DaySummaryLayout.slotDurationMs * 2,
                    slotEndMs: DaySummaryLayout.slotDurationMs * 3,
                    state: "skipped_idle",
                    facts: DaySlotFacts(apps: [])
                ),
                DaySlotSummary(
                    slotStartMs: 0,
                    slotEndMs: DaySummaryLayout.slotDurationMs,
                    state: "degraded",
                    facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)])
                ),
            ]
        )
        let text = DaySummaryClipboard.dayText(day, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(text.hasPrefix("## 2026-08-15\n"), text)
        let earlier = text.range(of: "Zed 10m")!.lowerBound
        let later = text.range(of: "Later work")!.lowerBound
        XCTAssertLessThan(earlier, later, "copied text must read forward in time")
        XCTAssertTrue(text.contains("  - shipped the fix"), text)
        XCTAssertTrue(text.contains("(Not summarised)"), "fallback rows say so in copies too")
        XCTAssertFalse(text.contains("Idle"), "idle slots must not leak into pasted notes")

        let older = DaySummary(day: "2026-08-14", dayStartMs: -86_400_000, dayEndMs: 0, slots: [])
        let history = DaySummaryClipboard.historyText([day, older])
        XCTAssertLessThan(
            history.range(of: "2026-08-14")!.lowerBound,
            history.range(of: "2026-08-15")!.lowerBound,
            "days also read forward in time"
        )
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
