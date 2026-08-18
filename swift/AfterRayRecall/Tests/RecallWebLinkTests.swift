import XCTest
@testable import AfterRayRecall

/// `RecallMoment.url` is captured, unvalidated, from whatever the foreground
/// app published in its accessibility tree, and the identity capsule turns it
/// into something the user can click. These tests pin the two halves of that:
/// what may become a link at all, and how it reads once it is one.
final class RecallWebLinkTests: XCTestCase {
    func testHttpAndHttpsBecomeLinks() {
        XCTAssertEqual(RecallWebLink(captured: "https://example.com/")?.url.scheme, "https")
        XCTAssertEqual(RecallWebLink(captured: "http://example.com/")?.url.scheme, "http")
    }

    /// The capsule hands `url` straight to `NSWorkspace`, so anything that is
    /// not a web page must not survive parsing — a captured `file:` path or a
    /// private scheme would otherwise become a click that opens a local file
    /// or invokes an arbitrary registered handler.
    func testNonWebSchemesAreNotLinks() {
        for captured in [
            "file:///Users/someone/Documents/private.pdf",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "afterray://moment/abc",
            "mailto:someone@example.com",
            "ftp://example.com/file",
        ] {
            XCTAssertNil(RecallWebLink(captured: captured), "\(captured) must not be openable")
        }
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertNotNil(RecallWebLink(captured: "HTTPS://example.com/"))
    }

    func testEmptyAndHostlessValuesAreNotLinks() {
        XCTAssertNil(RecallWebLink(captured: nil))
        XCTAssertNil(RecallWebLink(captured: "   "))
        XCTAssertNil(RecallWebLink(captured: "not a url at all"))
        XCTAssertNil(RecallWebLink(captured: "https:///just-a-path"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(RecallWebLink(captured: "  https://example.com/  ")?.display, "example.com")
    }

    func testDisplayDropsSchemeWwwAndTrailingSlash() {
        XCTAssertEqual(RecallWebLink(captured: "https://www.example.com/")?.display, "example.com")
        XCTAssertEqual(
            RecallWebLink(captured: "https://example.com/docs/recall/")?.display,
            "example.com/docs/recall"
        )
    }

    func testDisplayKeepsPortAndDecodesPath() {
        XCTAssertEqual(
            RecallWebLink(captured: "http://localhost:3030/search")?.display,
            "localhost:3030/search"
        )
        XCTAssertEqual(
            RecallWebLink(captured: "https://example.com/%E6%97%B6%E9%97%B4%E8%BD%B4")?.display,
            "example.com/时间轴"
        )
    }

    /// A query or fragment is elided, not shown: a tracking-laden address is
    /// mostly noise in a 320pt capsule. The elision must not reach `url` —
    /// the click still has to land on the exact page that was captured.
    func testQueryAndFragmentAreElidedInDisplayButKeptInTheLink() {
        let link = RecallWebLink(captured: "https://example.com/a?utm_source=x&utm_campaign=y#top")
        XCTAssertEqual(link?.display, "example.com/a…")
        XCTAssertEqual(
            link?.url.absoluteString,
            "https://example.com/a?utm_source=x&utm_campaign=y#top"
        )
    }

    func testMomentExposesItsLinkOnlyForWebFrames() {
        XCTAssertEqual(moment(url: "https://example.com/page")?.webLink?.display, "example.com/page")
        XCTAssertNil(moment(url: "file:///tmp/report.pdf")?.webLink)
        XCTAssertNil(moment(url: nil)?.webLink)
    }

    private func moment(url: String?) -> RecallMoment? {
        RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: 0,
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Example Domain",
            url: url
        )
    }
}
