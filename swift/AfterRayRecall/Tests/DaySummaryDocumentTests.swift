import XCTest
@testable import AfterRayRecall

/// The document builder is the selection fix: one attributed string, so a
/// selection can run across bullets, rows and days. These tests pin the
/// structure the hosting `NSTextView` relies on — ranges, links, order —
/// without ever creating a view.
final class DaySummaryDocumentTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let dayMs: Int64 = 86_400_000

    func testDocumentIsOneContinuousStringAcrossDays() {
        let (document, layout) = DaySummaryDocument.build(
            summaries: [day(start: dayMs, titles: ["afternoon", "morning"]), day(start: 0, titles: ["earlier"])],
            nowMs: dayMs * 2,
            timeZone: utc
        )
        let text = document.string
        XCTAssertTrue(text.contains("afternoon"))
        XCTAssertTrue(text.contains("earlier"))
        XCTAssertEqual(layout.dayRanges.count, 2)
        // Days render in the order given (newest first); the second day's
        // heading sits after the first day's slots in the same string.
        XCTAssertLessThan(
            layout.dayRanges[0].range.location,
            layout.dayRanges[1].range.location
        )
    }

    func testSlotsRenderNewestFirstWithinADay() {
        let (document, _) = DaySummaryDocument.build(
            summaries: [day(start: 0, titles: ["morning", "noon"])],
            nowMs: dayMs,
            timeZone: utc
        )
        let text = document.string
        // Slot helper assigns ascending start times in title order, so
        // "noon" (later) must appear before "morning" in a newest-first doc.
        let noon = text.range(of: "noon")!.lowerBound
        let morning = text.range(of: "morning")!.lowerBound
        XCTAssertLessThan(noon, morning)
    }

    func testSlotRangesCoverTheirTextAndCarryLinks() {
        let summary = day(start: 0, titles: ["only slot"], bullets: ["read the code", "wrote a fix"])
        let (document, layout) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        let slotStart = summary.slots[0].slotStartMs
        let range = try! XCTUnwrap(layout.slotRanges[slotStart])
        let slotText = (document.string as NSString).substring(with: range)
        XCTAssertTrue(slotText.contains("only slot"))
        XCTAssertTrue(slotText.contains("read the code wrote a fix"))
        XCTAssertFalse(slotText.contains("·\t"), "the single description is prose, not a list item")
        XCTAssertTrue(slotText.contains("Full details"))
        XCTAssertFalse(slotText.localizedCaseInsensitiveContains("json"))

        let timeRange = try! XCTUnwrap(layout.timeRanges[slotStart])
        let attributedTimeColor = document.attribute(
            .foregroundColor,
            at: timeRange.location,
            effectiveRange: nil
        ) as? NSColor
        let timeColor = try! XCTUnwrap(attributedTimeColor?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(timeColor.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(timeColor.greenComponent, 0.20, accuracy: 0.001)
        XCTAssertEqual(timeColor.blueComponent, 0.14, accuracy: 0.001)

        let descriptionLocation = (document.string as NSString).range(of: "read the code").location
        let descriptionStyle = document.attribute(
            .paragraphStyle,
            at: descriptionLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(descriptionStyle?.firstLineHeadIndent, DaySummaryDocument.textX)
        XCTAssertEqual(descriptionStyle?.headIndent, DaySummaryDocument.textX)

        // The time chip links to the slot so clicking it jumps the timeline.
        var foundLink = false
        document.enumerateAttribute(.link, in: range) { value, _, _ in
            if let url = value as? URL,
               DaySummaryDocument.slotStart(from: url) == slotStart
            {
                foundLink = true
            }
        }
        XCTAssertTrue(foundLink, "the slot's time chip must link to it")
    }

    func testTimestampAndDetailsLinksRouteIndependently() throws {
        let summary = day(start: 0, titles: ["only slot"], bullets: ["first", "second"])
        let slotStart = try XCTUnwrap(summary.slots.first?.slotStartMs)
        let (document, layout) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            expandedSlotStarts: [slotStart],
            timeZone: utc
        )
        let range = try XCTUnwrap(layout.slotRanges[slotStart])
        var routes: Set<String> = []
        document.enumerateAttribute(.link, in: range) { value, _, _ in
            guard let url = value as? URL else { return }
            if DaySummaryDocument.slotStart(from: url) == slotStart { routes.insert("timestamp") }
            if DaySummaryDocument.detailsSlotStart(from: url) == slotStart { routes.insert("details") }
        }
        XCTAssertEqual(routes, ["timestamp", "details"])
        let slotText = (document.string as NSString).substring(with: range)
        XCTAssertTrue(slotText.contains("first"))
        XCTAssertTrue(slotText.contains("second"))
    }

    func testLayoutLookupsResolveCharacterPositions() {
        let first = day(start: dayMs, titles: ["newest"])
        let second = day(start: 0, titles: ["older"])
        let (document, layout) = DaySummaryDocument.build(
            summaries: [first, second],
            nowMs: dayMs * 2,
            timeZone: utc
        )
        let olderStart = second.slots[0].slotStartMs
        let olderRange = try! XCTUnwrap(layout.slotRanges[olderStart])
        XCTAssertEqual(layout.slotStart(at: olderRange.location + 1), olderStart)
        XCTAssertEqual(layout.dayStart(at: olderRange.location + 1), 0)
        XCTAssertEqual(layout.dayStart(at: layout.dayRanges[0].range.location), dayMs)
        XCTAssertNil(layout.slotStart(at: document.length + 10))
    }

    func testFallbackRowsCarryTheirBadge() {
        let summary = DaySummary(
            day: "1970-01-01",
            dayStartMs: 0,
            dayEndMs: dayMs,
            slots: [
                DaySlotSummary(
                    slotStartMs: 0,
                    slotEndMs: DaySummaryLayout.slotDurationMs,
                    state: "failed",
                    facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)])
                ),
            ]
        )
        let (document, _) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        XCTAssertTrue(document.string.contains("Summary failed"))
    }

    /// Idle half-hours stay on the wire but never become document rows —
    /// the feed is only activity worth reading.
    func testIdleSlotsAreNotRendered() {
        let idleStart = DaySummaryLayout.slotDurationMs
        let summary = DaySummary(
            day: "1970-01-01",
            dayStartMs: 0,
            dayEndMs: dayMs,
            slots: [
                DaySlotSummary(
                    slotStartMs: 0,
                    slotEndMs: DaySummaryLayout.slotDurationMs,
                    state: "done",
                    facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)]),
                    title: "Real work"
                ),
                DaySlotSummary(
                    slotStartMs: idleStart,
                    slotEndMs: idleStart + DaySummaryLayout.slotDurationMs,
                    state: "skipped_idle",
                    facts: DaySlotFacts(apps: [])
                ),
            ]
        )
        let (document, layout) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        XCTAssertTrue(document.string.contains("Real work"))
        XCTAssertFalse(document.string.contains("Idle"))
        XCTAssertNil(layout.slotRanges[idleStart])
        XCTAssertNil(layout.timeRanges[idleStart])
    }

    /// All-caps runs read as shouting in a dense list; the document is
    /// Title case throughout, headings included.
    func testDocumentNeverShouts() {
        let (document, layout) = DaySummaryDocument.build(
            summaries: [day(start: 0, titles: ["a slot"])],
            nowMs: 0,
            timeZone: utc
        )
        XCTAssertEqual(layout.dayRanges.first?.heading.hasPrefix("Today"), true)
        let words = document.string.split(whereSeparator: { !$0.isLetter })
        let strings = words.map { String($0) }
        let shouted = strings.filter {
            $0.count > 2 && $0 == $0.uppercased() && $0 != $0.lowercased()
        }
        XCTAssertTrue(shouted.isEmpty, "found all-caps words: \(shouted)")
    }

    /// An attachment with no image is sized from its run's font instead of
    /// its bounds, and the icon line's separators are hairline-thin — which
    /// left every icon drawn as a two-pixel slice of itself. Both halves of
    /// the guard are pinned here: the image is never nil, and the run
    /// carries a font tall enough to hold an icon.
    func testIconAttachmentsAreNeverSizedFromAHairlineFont() {
        let attachment = DaySummaryDocument.AppIconAttachment(bundleIdentifier: nil)
        XCTAssertNotNil(attachment.image, "an image-less attachment is sized from its font")
        XCTAssertEqual(attachment.bounds.height, 14)

        let summary = day(start: 0, titles: ["a slot"])
        let (document, _) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        var iconRuns = 0
        document.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: document.length)
        ) { value, range, _ in
            guard value is DaySummaryDocument.AppIconAttachment else { return }
            iconRuns += 1
            let font = document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            XCTAssertEqual(font?.pointSize, DaySummaryDocument.iconRunFont.pointSize)
        }
        XCTAssertGreaterThan(iconRuns, 0, "the fixture slot has apps, so it has icons")
    }

    /// Collapsing an unresolvable icon must leave nothing to draw: bounds
    /// with no size, and an image so it cannot fall back to a glyph.
    func testCollapsedIconsDrawNothing() {
        let attachment = DaySummaryDocument.AppIconAttachment(bundleIdentifier: "com.example.gone")
        attachment.collapse()
        XCTAssertEqual(attachment.bounds, .zero)
        XCTAssertNotNil(attachment.image)
    }

    func testSlotLinkRoundTrips() {
        let url = DaySummaryDocument.slotLink(startMs: 1_786_698_000_000)
        XCTAssertEqual(DaySummaryDocument.slotStart(from: url), 1_786_698_000_000)
        XCTAssertNil(DaySummaryDocument.slotStart(from: URL(string: "https://example.com")!))
    }

    // ------------------------------------------------------------ helpers

    /// A day whose slots take ascending start times in `titles` order, so a
    /// test can reason about which title is "later".
    private func day(start: Int64, titles: [String], bullets: [String] = []) -> DaySummary {
        let slots = titles.enumerated().map { index, title in
            DaySlotSummary(
                slotStartMs: start + Int64(index) * DaySummaryLayout.slotDurationMs,
                slotEndMs: start + Int64(index + 1) * DaySummaryLayout.slotDurationMs,
                state: "done",
                facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)], momentCount: 3),
                title: title,
                bullets: bullets
            )
        }
        return DaySummary(
            day: DaySummaryLayout.localDayKey(ms: start, timeZone: utc),
            dayStartMs: start,
            dayEndMs: start + dayMs,
            slots: slots
        )
    }
}
