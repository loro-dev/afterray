@testable import AfterRayCapturePolicy
import CoreGraphics
import XCTest

final class DisplaySelectionTests: XCTestCase {
    private let displays = [
        CaptureDisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        CaptureDisplayGeometry(id: 2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440)),
        CaptureDisplayGeometry(id: 3, frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920)),
    ]

    func testSelectsDisplayContainingFocusedWindow() {
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: CGRect(x: 2300, y: 120, width: 900, height: 700),
                displays: displays,
                fallbackDisplayID: 1
            ),
            2
        )
    }

    func testSelectsDisplayWithLargestWindowIntersection() {
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: CGRect(x: 1700, y: 100, width: 900, height: 700),
                displays: displays,
                fallbackDisplayID: 1
            ),
            2
        )
    }

    func testSupportsDisplaysWithNegativeDesktopCoordinates() {
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: CGRect(x: -900, y: 300, width: 700, height: 1000),
                displays: displays,
                fallbackDisplayID: 1
            ),
            3
        )
    }

    func testFallsBackWhenWindowFrameIsUnavailableOrOffscreen() {
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: nil,
                displays: displays,
                fallbackDisplayID: 1
            ),
            1
        )
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: CGRect(x: 10_000, y: 10_000, width: 400, height: 300),
                displays: displays,
                fallbackDisplayID: 1
            ),
            1
        )
    }

    func testMainDisplayWinsAnExactIntersectionTie() {
        XCTAssertEqual(
            CaptureDisplaySelection.displayID(
                for: CGRect(x: 1720, y: 100, width: 400, height: 600),
                displays: displays,
                fallbackDisplayID: 1
            ),
            1
        )
    }
}
