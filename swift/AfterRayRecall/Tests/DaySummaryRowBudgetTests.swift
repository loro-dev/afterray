import XCTest
@testable import AfterRayRecall

/// A row's `body` runs whenever the window moves, and the estimator behind the
/// window runs over *every* loaded row on every pass. Whatever a row derives to
/// draw itself must therefore be cheap — windowing bounds how many rows are
/// mounted, never how often the model is rebuilt.
///
/// This has now been the same bug three times: `expandedSections` runs the
/// card body through `AttributedString(markdown:)` once per line, ~1.2ms a
/// card, and it was reached first from the height estimator, then from the
/// row's `sections` computed property — which `body` touched even when the
/// card was collapsed, just to decide whether to draw a "Full details" link.
/// 91 rows of that is ~110ms per pass, seven frames of a 60fps budget.
final class DaySummaryRowBudgetTests: XCTestCase {
    private func slot(_ start: Int64) -> DaySlotSummary {
        var lines: [String] = []
        for index in 0..<24 {
            if index % 6 == 0 {
                lines.append("## Section \(index)")
            } else {
                lines.append(
                    "- Worked on **the parser** and [a citation](afterray://moment/\(index))"
                        + " with `code` spans and ordinary prose that wraps."
                )
            }
        }
        return DaySlotSummary(
            slotStartMs: start,
            slotEndMs: start + 3_600_000,
            state: "summarized",
            facts: DaySlotFacts(apps: [DayAppFact(name: "Xcode", ms: 1_800_000)]),
            title: "A reasonably long slot title that wraps across two lines",
            description: "A short description line for the collapsed row.",
            details: lines.joined(separator: "\n")
        )
    }

    func testDrawingACollapsedWindowStaysWithinAFrame() {
        let slots = (0..<84).map { slot(Int64($0) * 3_600_000) }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            for slot in slots {
                // Exactly what `DaySummaryRow.body` derives for a collapsed card.
                _ = DaySummaryLayout.rowText(slot: slot)
                _ = DaySummaryLayout.hasExpandableDetail(slot: slot)
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 10
        XCTAssertLessThan(
            ms,
            8.0,
            "a collapsed row must not parse its card body; \(slots.count) rows took \(ms)ms"
        )
    }

    /// The parse is fine — once, for the one card the user opened.
    func testExpandingOneCardIsWhereTheParseBelongs() {
        let one = slot(0)
        let start = CFAbsoluteTimeGetCurrent()
        _ = DaySummaryLayout.expandedSections(slot: one)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertFalse(DaySummaryLayout.expandedSections(slot: one).isEmpty)
        print("PROBE one expanded card = \(String(format: "%.2f", ms)) ms")
    }
}
