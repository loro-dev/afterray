import XCTest

@testable import AfterRayRecall

final class ImmersiveQueryModeTests: XCTestCase {
    func testTabReturnsToWhereItStarted() {
        var mode = ImmersiveQueryMode.search
        mode.toggle()
        XCTAssertEqual(mode, .ask)
        mode.toggle()
        XCTAssertEqual(mode, .search, "Tab has to be its own undo, or the key is a trap")
    }

    /// The shortcut is only discoverable from the placeholder, so both modes
    /// must name it — and each must point at the mode it is *not* in.
    func testBothPlaceholdersTeachTab() {
        for mode in ImmersiveQueryMode.allCases {
            XCTAssertTrue(
                mode.placeholder.contains("Tab"),
                "\(mode) placeholder hides the only hint the shortcut has"
            )
        }
        XCTAssertTrue(ImmersiveQueryMode.search.placeholder.contains("ask"))
        XCTAssertTrue(ImmersiveQueryMode.ask.placeholder.contains("search"))
    }

    func testEveryModeIsLabelledDistinctly() {
        let titles = Set(ImmersiveQueryMode.allCases.map(\.title))
        let symbols = Set(ImmersiveQueryMode.allCases.map(\.symbol))
        XCTAssertEqual(titles.count, ImmersiveQueryMode.allCases.count)
        XCTAssertEqual(symbols.count, ImmersiveQueryMode.allCases.count)
    }
}
