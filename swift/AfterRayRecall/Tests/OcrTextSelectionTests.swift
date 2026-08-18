import XCTest
@testable import AfterRayRecall

/// The selection model behind the transparent text layer. Everything here is
/// geometry and string slicing, so it is testable without a window: what the
/// view adds on top is mouse plumbing.
final class OcrTextSelectionTests: XCTestCase {
    /// A full-frame content rect, so a unit-square region maps 1:1 to points
    /// and the expected values in these tests can be read off by hand.
    private let content = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)

    /// `top` and `height` are in flipped, top-left-origin points; the helper
    /// converts back to Vision's bottom-left unit square so the tests read the
    /// way the screen looks.
    private func region(
        _ text: String,
        x: Double,
        top: Double,
        width: Double,
        height: Double
    ) -> OcrRegion {
        OcrRegion(
            text: text,
            confidence: 0.9,
            x: x / 1_000,
            y: (1_000 - top - height) / 1_000,
            width: width / 1_000,
            height: height / 1_000
        )
    }

    private func layout(_ regions: [OcrRegion]) -> OcrTextLayout {
        OcrTextLayout.build(regions: regions, contentRect: content)
    }

    private func position(_ line: Int, _ character: Int) -> OcrTextPosition {
        OcrTextPosition(line: line, character: character)
    }

    // MARK: - Reading order

    func testLinesAreOrderedTopToBottomThenLeftToRight() {
        let built = layout([
            region("third", x: 100, top: 200, width: 100, height: 20),
            region("second", x: 300, top: 100, width: 100, height: 20),
            region("first", x: 100, top: 100, width: 100, height: 20),
        ])
        XCTAssertEqual(built.lines.map(\.text), ["first", "second", "third"])
    }

    /// Boxes on the same visual row are never perfectly aligned — Vision hugs
    /// the ink, so a row of mixed cap heights wobbles by a few points. Ordering
    /// those by raw y would interleave the row with the next one.
    func testSlightlyMisalignedBoxesStillShareARow() {
        let built = layout([
            region("right", x: 300, top: 104, width: 100, height: 18),
            region("left", x: 100, top: 100, width: 100, height: 20),
            region("below", x: 100, top: 140, width: 100, height: 20),
        ])
        XCTAssertEqual(built.lines.map(\.text), ["left", "right", "below"])
    }

    func testEmptyAndDegenerateRegionsAreDropped() {
        let built = layout([
            region("   ", x: 100, top: 100, width: 100, height: 20),
            region("zero width", x: 100, top: 140, width: 0, height: 20),
            region("kept", x: 100, top: 180, width: 100, height: 20),
        ])
        XCTAssertEqual(built.lines.map(\.text), ["kept"])
    }

    func testBuildingAgainstAnEmptyContentRectYieldsNothing() {
        let built = OcrTextLayout.build(
            regions: [region("text", x: 100, top: 100, width: 100, height: 20)],
            contentRect: .zero
        )
        XCTAssertTrue(built.isEmpty)
        XCTAssertNil(built.fullRange)
    }

    // MARK: - Hit testing

    func testOnlyGlyphBoxesCountAsText() {
        let built = layout([region("hello", x: 100, top: 100, width: 100, height: 20)])

        XCTAssertNotNil(built.lineIndex(at: CGPoint(x: 150, y: 110), padding: 3))
        // Just outside the box but inside the slack.
        XCTAssertNotNil(built.lineIndex(at: CGPoint(x: 202, y: 110), padding: 3))
        // The letterbox and the empty desktop around the words are not text —
        // a drag starting here has to reach the timeline instead.
        XCTAssertNil(built.lineIndex(at: CGPoint(x: 400, y: 110), padding: 3))
        XCTAssertNil(built.lineIndex(at: CGPoint(x: 150, y: 400), padding: 3))
    }

    func testADragOffTheBoxesStillResolvesToTheNearestLine() {
        let built = layout([
            region("first", x: 100, top: 100, width: 100, height: 20),
            region("second", x: 100, top: 200, width: 100, height: 20),
        ])

        // Above everything, below everything, and out in the right margin.
        XCTAssertEqual(built.nearestLineIndex(at: CGPoint(x: 150, y: 0)), 0)
        XCTAssertEqual(built.nearestLineIndex(at: CGPoint(x: 150, y: 900)), 1)
        XCTAssertEqual(built.nearestLineIndex(at: CGPoint(x: 900, y: 205)), 1)
        XCTAssertNil(layout([]).nearestLineIndex(at: .zero))
    }

    // MARK: - Ranges

    func testARangeIsOrderedWhicheverWayTheDragWent() {
        let forwards = OcrTextRange(anchor: position(0, 2), head: position(1, 4))
        let backwards = OcrTextRange(anchor: position(1, 4), head: position(0, 2))
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.start, position(0, 2))
        XCTAssertEqual(forwards.end, position(1, 4))
        XCTAssertTrue(OcrTextRange(anchor: position(0, 2), head: position(0, 2)).isEmpty)
    }

    func testPositionsAreClampedToTheLine() {
        let built = layout([region("abc", x: 100, top: 100, width: 100, height: 20)])
        XCTAssertEqual(built.clamped(position(9, 9)), position(0, 3))
        XCTAssertEqual(built.clamped(position(-1, -1)), position(0, 0))
        XCTAssertEqual(layout([]).clamped(position(3, 3)), position(0, 0))
    }

    // MARK: - What lands on the pasteboard

    func testCopyingWithinOneLineSlicesIt() {
        let built = layout([region("quarterly roadmap", x: 100, top: 100, width: 200, height: 20)])
        let range = OcrTextRange(anchor: position(0, 10), head: position(0, 17))
        XCTAssertEqual(built.string(for: range), "roadmap")
    }

    func testCopyingAcrossLinesJoinsThemWithNewlines() {
        let built = layout([
            region("first line", x: 100, top: 100, width: 200, height: 20),
            region("second line", x: 100, top: 140, width: 200, height: 20),
            region("third line", x: 100, top: 180, width: 200, height: 20),
        ])
        let range = OcrTextRange(anchor: position(0, 6), head: position(2, 5))
        XCTAssertEqual(built.string(for: range), "line\nsecond line\nthird")
    }

    func testAnEmptyRangeCopiesNothing() {
        let built = layout([region("text", x: 100, top: 100, width: 100, height: 20)])
        XCTAssertEqual(built.string(for: OcrTextRange(anchor: position(0, 2), head: position(0, 2))), "")
    }

    func testSelectAllCoversEveryLine() {
        let built = layout([
            region("first", x: 100, top: 100, width: 100, height: 20),
            region("second", x: 100, top: 140, width: 100, height: 20),
        ])
        let all = try? XCTUnwrap(built.fullRange)
        XCTAssertEqual(built.string(for: all ?? OcrTextRange(anchor: position(0, 0), head: position(0, 0))), "first\nsecond")
    }

    /// Copy is the whole point of the feature, so the text is the recognized
    /// string verbatim — never something reassembled from glyph positions.
    func testCopiedTextIsTheRecognizedStringIncludingCjk() {
        let built = layout([region("拖动即可选中文字", x: 100, top: 100, width: 200, height: 20)])
        let all = built.fullRange
        XCTAssertEqual(built.string(for: all!), "拖动即可选中文字")
    }

    // MARK: - Word and line selection

    func testDoubleClickSelectsTheWordUnderThePointer() {
        let built = layout([region("quarterly roadmap review", x: 100, top: 100, width: 300, height: 20)])
        let range = built.wordRange(at: position(0, 12))
        XCTAssertEqual(built.string(for: range), "roadmap")
    }

    /// A Chinese line has no spaces to split on. Falling back to "expand until
    /// whitespace" would select the entire line on every double click.
    func testDoubleClickOnCjkSelectsAWordNotTheWholeLine() {
        let built = layout([region("今天天气很好", x: 100, top: 100, width: 200, height: 20)])
        let range = built.wordRange(at: position(0, 3))
        let selected = built.string(for: range)
        XCTAssertFalse(selected.isEmpty)
        XCTAssertLessThan(selected.count, 6)
    }

    func testTripleClickSelectsTheWholeLine() {
        let built = layout([
            region("first line", x: 100, top: 100, width: 200, height: 20),
            region("second line", x: 100, top: 140, width: 200, height: 20),
        ])
        XCTAssertEqual(built.string(for: built.lineRange(at: position(1, 3))), "second line")
    }

    // MARK: - Selection rectangles

    func testSelectionRectsSpanWholeLinesInTheMiddle() {
        let built = layout([
            region("first", x: 100, top: 100, width: 200, height: 20),
            region("second", x: 100, top: 140, width: 200, height: 20),
            region("third", x: 100, top: 180, width: 200, height: 20),
        ])
        let range = OcrTextRange(anchor: position(0, 2), head: position(2, 3))
        // A stub for the view's lazily built CoreText metrics: 10pt per
        // character from the left edge of the line.
        let rects = built.selectionRects(for: range) { position in
            built.lines[position.line].rect.minX + CGFloat(position.character) * 10
        }

        XCTAssertEqual(rects.count, 3)
        // First line: from the caret to the end of the box.
        XCTAssertEqual(rects[0].minX, 120, accuracy: 0.001)
        XCTAssertEqual(rects[0].maxX, 300, accuracy: 0.001)
        // Middle line: all of it.
        XCTAssertEqual(rects[1].minX, 100, accuracy: 0.001)
        XCTAssertEqual(rects[1].maxX, 300, accuracy: 0.001)
        // Last line: from the start of the box to the caret.
        XCTAssertEqual(rects[2].minX, 100, accuracy: 0.001)
        XCTAssertEqual(rects[2].maxX, 130, accuracy: 0.001)
        XCTAssertEqual(rects[0].minY, 100, accuracy: 0.001)
        XCTAssertEqual(rects[0].height, 20, accuracy: 0.001)
    }

    func testAnEmptySelectionDrawsNothing() {
        let built = layout([region("text", x: 100, top: 100, width: 100, height: 20)])
        let empty = OcrTextRange(anchor: position(0, 1), head: position(0, 1))
        XCTAssertTrue(built.selectionRects(for: empty) { _ in 0 }.isEmpty)
    }

    // MARK: - Caret metrics

    func testCaretOffsetsSpanTheBoxAndNeverGoBackwards() {
        let built = layout([region("quarterly roadmap", x: 100, top: 100, width: 200, height: 20)])
        let offsets = OcrCaretMetrics.caretOffsets(for: built.lines[0])

        XCTAssertEqual(offsets.count, 18)
        XCTAssertEqual(offsets.first, 100)
        // Pinned to the right edge so a drag past the line always takes all
        // of it, whatever the typographic width came out as.
        XCTAssertEqual(offsets.last, 300)
        XCTAssertEqual(offsets, offsets.sorted())
    }

    func testCaretOffsetsForAnEmptyLineCollapseToItsOrigin() {
        let line = OcrTextLine(text: "", characters: [], rect: CGRect(x: 40, y: 0, width: 80, height: 20))
        XCTAssertEqual(OcrCaretMetrics.caretOffsets(for: line), [40])
    }

    func testCharacterIndexPicksTheNearerBoundary() {
        let offsets: [CGFloat] = [0, 10, 20, 30]
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: -5, offsets: offsets), 0)
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 4, offsets: offsets), 0)
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 6, offsets: offsets), 1)
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 26, offsets: offsets), 3)
        // Dead centre between two carets resolves left, consistently.
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 25, offsets: offsets), 2)
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 999, offsets: offsets), 3)
        XCTAssertEqual(OcrCaretMetrics.characterIndex(forX: 5, offsets: []), 0)
    }
}
