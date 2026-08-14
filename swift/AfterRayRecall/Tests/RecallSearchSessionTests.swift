import XCTest
@testable import AfterRayRecall

final class RecallSearchSessionTests: XCTestCase {
    private func hit(
        moment: String,
        at capturedAtMs: Int64,
        source: String = "ocr",
        text: String = "match",
        score: Double = 1
    ) -> RecallSearchHit {
        RecallSearchHit(
            momentId: moment,
            sessionId: "s1",
            capturedAtMs: capturedAtMs,
            source: source,
            text: text,
            score: score
        )
    }

    func testFramesAreNewestFirstRegardlessOfRankOrder() {
        // The daemon returns hits ranked by relevance, not by time.
        let session = RecallSearchSession.make(
            query: "deck",
            hits: [
                hit(moment: "old", at: 1_000, score: 9),
                hit(moment: "new", at: 9_000, score: 2),
                hit(moment: "mid", at: 5_000, score: 5),
            ]
        )

        XCTAssertEqual(session?.frames.map(\.momentId), ["new", "mid", "old"])
        XCTAssertEqual(session?.selectedIndex, 0)
        XCTAssertEqual(session?.selectedFrame?.momentId, "new")
    }

    func testSeveralHitsOnOneFrameFoldIntoOneCell() {
        let session = RecallSearchSession.make(
            query: "roadmap",
            hits: [
                hit(moment: "m1", at: 1_000, source: "ocr", text: "on screen", score: 1),
                hit(moment: "m1", at: 1_000, source: "window", text: "roadmap.key", score: 4),
                hit(moment: "m2", at: 2_000, source: "ocr", text: "elsewhere", score: 2),
            ]
        )

        XCTAssertEqual(session?.frames.count, 2)
        // Two frames but three matches — the counter has to say both.
        XCTAssertEqual(session?.totalHits, 3)
        XCTAssertEqual(session?.tallyLabel, "3 matches · 2 frames")

        let folded = session?.frames.first { $0.momentId == "m1" }
        XCTAssertEqual(folded?.hits.count, 2)
        // Excerpt and source come from the strongest evidence on the frame.
        XCTAssertEqual(folded?.excerpt, "roadmap.key")
        XCTAssertEqual(folded?.primarySource, "window")
    }

    func testHitsWithoutAMomentAreDropped() {
        // Transcript evidence with no preceding frame cannot be opened.
        let session = RecallSearchSession.make(
            query: "call",
            hits: [
                hit(moment: "", at: 1_000, source: "transcript"),
                hit(moment: "m1", at: 2_000),
            ]
        )

        XCTAssertEqual(session?.frames.map(\.momentId), ["m1"])
        XCTAssertEqual(session?.totalHits, 1)
    }

    func testNoUsableHitsProducesNoSession() {
        XCTAssertNil(RecallSearchSession.make(query: "nothing", hits: []))
        XCTAssertNil(
            RecallSearchSession.make(query: "nothing", hits: [hit(moment: "", at: 1)])
        )
    }

    func testSteppingClampsAtBothEnds() {
        var session = RecallSearchSession.make(
            query: "q",
            hits: [
                hit(moment: "a", at: 3_000),
                hit(moment: "b", at: 2_000),
                hit(moment: "c", at: 1_000),
            ]
        )!

        XCTAssertEqual(session.steppedIndex(by: -1), 0, "already at the newest")
        XCTAssertEqual(session.steppedIndex(by: 1), 1)

        session.selectedIndex = 2
        XCTAssertEqual(session.steppedIndex(by: 1), 2, "already at the oldest")
        XCTAssertEqual(session.steppedIndex(by: -5), 0)
    }

    func testLabelsCountFramesNotHits() {
        var session = RecallSearchSession.make(
            query: "q",
            hits: [hit(moment: "a", at: 2_000), hit(moment: "b", at: 1_000)]
        )!
        XCTAssertEqual(session.positionLabel, "1/2")
        session.selectedIndex = 1
        XCTAssertEqual(session.positionLabel, "2/2")

        let single = RecallSearchSession.make(query: "q", hits: [hit(moment: "a", at: 1)])!
        XCTAssertEqual(single.tallyLabel, "1 match · 1 frame")
    }

    func testIndexLookupFindsAFrameByMomentID() {
        let session = RecallSearchSession.make(
            query: "q",
            hits: [hit(moment: "a", at: 2_000), hit(moment: "b", at: 1_000)]
        )!
        XCTAssertEqual(session.index(ofMomentID: "b"), 1)
        XCTAssertNil(session.index(ofMomentID: "missing"))
    }

    func testOutOfRangeSelectionIsClamped() {
        let session = RecallSearchSession(
            query: "q",
            frames: [SearchFrame(momentId: "a", capturedAtMs: 1, hits: [])],
            totalHits: 1,
            selectedIndex: 9
        )
        XCTAssertEqual(session.selectedIndex, 0)
    }
}
