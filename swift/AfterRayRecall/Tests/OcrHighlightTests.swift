import XCTest
@testable import AfterRayRecall

final class OcrHighlightTests: XCTestCase {
    private func region(
        _ text: String,
        x: Double = 0,
        y: Double = 0,
        width: Double = 0.1,
        height: Double = 0.1
    ) -> OcrRegion {
        OcrRegion(text: text, confidence: 0.9, x: x, y: y, width: width, height: height)
    }

    func testContentRectLetterboxesOnTheAxisWithSlack() {
        // 2:1 picture in a 1:1 view — bars above and below.
        let pillarless = OcrHighlight.contentRect(
            pixelSize: CGSize(width: 200, height: 100),
            viewSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(pillarless, CGRect(x: 0, y: 25, width: 100, height: 50))

        // 1:2 picture in a 1:1 view — bars left and right.
        let pillarboxed = OcrHighlight.contentRect(
            pixelSize: CGSize(width: 100, height: 200),
            viewSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(pillarboxed, CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    func testContentRectFillsWhenAspectMatches() {
        let exact = OcrHighlight.contentRect(
            pixelSize: CGSize(width: 3456, height: 2234),
            viewSize: CGSize(width: 1728, height: 1117)
        )
        XCTAssertEqual(exact, CGRect(x: 0, y: 0, width: 1728, height: 1117))
    }

    func testContentRectIsEmptyForDegenerateSizes() {
        XCTAssertEqual(
            OcrHighlight.contentRect(pixelSize: .zero, viewSize: CGSize(width: 10, height: 10)),
            .zero
        )
        XCTAssertEqual(
            OcrHighlight.contentRect(pixelSize: CGSize(width: 10, height: 10), viewSize: .zero),
            .zero
        )
    }

    func testRectFlipsVisionYAxis() {
        let content = CGRect(x: 0, y: 0, width: 100, height: 100)

        // Vision y=0 is the *bottom* of the image, so a box sitting on the
        // bottom edge must land at the bottom in SwiftUI coordinates too.
        let bottom = OcrHighlight.rect(
            for: region("bottom", x: 0, y: 0, width: 1, height: 0.1),
            in: content
        )
        XCTAssertEqual(bottom, CGRect(x: 0, y: 90, width: 100, height: 10))

        let top = OcrHighlight.rect(
            for: region("top", x: 0, y: 0.9, width: 1, height: 0.1),
            in: content
        )
        XCTAssertEqual(top.minX, 0, accuracy: 0.001)
        XCTAssertEqual(top.minY, 0, accuracy: 0.001)
        XCTAssertEqual(top.width, 100, accuracy: 0.001)
        XCTAssertEqual(top.height, 10, accuracy: 0.001)
    }

    func testRectIsOffsetByTheLetterbox() {
        let content = CGRect(x: 10, y: 20, width: 100, height: 50)
        let box = OcrHighlight.rect(
            for: region("mid", x: 0.5, y: 0.5, width: 0.25, height: 0.5),
            in: content
        )
        XCTAssertEqual(box.minX, 60, accuracy: 0.001)
        XCTAssertEqual(box.minY, 20, accuracy: 0.001)
        XCTAssertEqual(box.width, 25, accuracy: 0.001)
        XCTAssertEqual(box.height, 25, accuracy: 0.001)
    }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        let regions = [region("Quarterly Roadmap"), region("café menu"), region("unrelated")]

        XCTAssertEqual(
            OcrHighlight.matching(regions: regions, query: "roadmap").map(\.text),
            ["Quarterly Roadmap"]
        )
        XCTAssertEqual(
            OcrHighlight.matching(regions: regions, query: "cafe").map(\.text),
            ["café menu"]
        )
    }

    func testMatchingReturnsNothingRatherThanGuessing() {
        let regions = [region("Quarterly Roadmap")]
        XCTAssertTrue(OcrHighlight.matching(regions: regions, query: "budget").isEmpty)
        XCTAssertTrue(OcrHighlight.matching(regions: regions, query: "").isEmpty)
        XCTAssertTrue(OcrHighlight.matching(regions: [], query: "roadmap").isEmpty)
    }

    func testEveryQueryTokenGetsAChanceToMatch() {
        let regions = [region("alpha"), region("beta"), region("gamma")]
        XCTAssertEqual(
            OcrHighlight.matching(regions: regions, query: "beta gamma").map(\.text),
            ["beta", "gamma"]
        )
    }

    func testQueryTokensDropFtsSyntaxAndNoiseWords() {
        XCTAssertEqual(OcrHighlight.queryTokens("\"quarterly roadmap\""), ["quarterly", "roadmap"])
        XCTAssertEqual(OcrHighlight.queryTokens("deck AND slides"), ["deck", "slides"])
        XCTAssertEqual(OcrHighlight.queryTokens("road*"), ["road"])
        // A lone Latin letter would light up nearly every region.
        XCTAssertEqual(OcrHighlight.queryTokens("a roadmap"), ["roadmap"])
        // A lone CJK character is a real query, though.
        XCTAssertEqual(OcrHighlight.queryTokens("图"), ["图"])
    }
}
