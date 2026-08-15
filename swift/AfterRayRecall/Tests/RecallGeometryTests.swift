import XCTest
@testable import AfterRayRecall

final class RecallGeometryTests: XCTestCase {
    func testControlBarClearsMacBookCameraSafeArea() {
        XCTAssertEqual(RecallGeometry.controlBarTopPadding(safeAreaTop: 0), 22)
        XCTAssertEqual(RecallGeometry.controlBarTopPadding(safeAreaTop: 32), 44)
    }

    func testOverlaySettingsLeavesRoomForMomentActions() {
        XCTAssertEqual(RecallGeometry.overlaySettingsReservedWidth(), 50)
        XCTAssertEqual(RecallGeometry.detailsMenuTopPadding(chromeTopPadding: 44), 96)
        XCTAssertEqual(RecallGeometry.daySummaryPanelWidth, 392)
        XCTAssertGreaterThanOrEqual(
            RecallGeometry.daySummaryMaxHeight,
            RecallGeometry.daySummaryListMaxHeight,
            "the list must fit inside the panel that frames it"
        )
        XCTAssertEqual(RecallGeometry.daySummaryCornerRadius, 16)
    }

    func testDragLeftMovesForwardAndClamps() {
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: -120, originIndex: 3, count: 10, pointsPerMoment: 50),
            5
        )
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: -1_000, originIndex: 3, count: 10, pointsPerMoment: 50),
            9
        )
    }

    func testDragRightMovesBackwardAndClamps() {
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: 105, originIndex: 6, count: 10, pointsPerMoment: 50),
            4
        )
        XCTAssertEqual(
            RecallGeometry.index(fromDragTranslation: 1_000, originIndex: 6, count: 10, pointsPerMoment: 50),
            0
        )
    }

    func testEmptyTimelineHasNoSelection() {
        XCTAssertNil(RecallGeometry.clampedIndex(0, count: 0))
        XCTAssertNil(RecallGeometry.index(fromDragTranslation: 10, originIndex: 0, count: 0, pointsPerMoment: 50))
    }

    func testLiveTimelinePositionMovesIntoAndBackOutOfHistory() {
        XCTAssertEqual(
            RecallGeometry.timelinePosition(
                fromDragTranslation: 54,
                originPosition: 4,
                momentCount: 4,
                pointsPerMoment: 54
            ),
            3
        )
        XCTAssertEqual(
            RecallGeometry.timelinePosition(
                fromDragTranslation: -54,
                originPosition: 3,
                momentCount: 4,
                pointsPerMoment: 54
            ),
            4
        )
    }

    func testRightwardScrollImmediatelyEntersHistoryFromLive() {
        XCTAssertEqual(RecallGeometry.liveScrollStep(delta: 0.1), -1)
        XCTAssertNil(RecallGeometry.liveScrollStep(delta: -0.1))
    }

    func testHSLRoundTripsPrimaryColorsAndAveragesHue() {
        let red = RecallColorMath.hsl(red: 1, green: 0, blue: 0)
        XCTAssertEqual(red.hue, 0, accuracy: 0.001)
        XCTAssertEqual(red.saturation, 1, accuracy: 0.001)

        let green = RecallColorMath.hsl(red: 0, green: 1, blue: 0)
        XCTAssertEqual(green.hue, 1.0 / 3.0, accuracy: 0.001)

        let blue = RecallColorMath.hsl(red: 0, green: 0, blue: 1)
        XCTAssertEqual(blue.hue, 2.0 / 3.0, accuracy: 0.001)

        let rgb = RecallColorMath.rgb(hue: 0.5, saturation: 0.6, lightness: 0.4)
        let back = RecallColorMath.hsl(red: rgb.red, green: rgb.green, blue: rgb.blue)
        XCTAssertEqual(back.hue, 0.5, accuracy: 0.01)
        XCTAssertEqual(back.saturation, 0.6, accuracy: 0.01)
        XCTAssertEqual(back.lightness, 0.4, accuracy: 0.01)
    }

    func testScrollDeltaIsBoundedAndDrainedAcrossDisplayFrames() {
        let accumulated = RecallGeometry.accumulatedScrollDelta(
            current: 80,
            incoming: 400
        )
        XCTAssertEqual(accumulated, 160)

        let firstFrame = RecallGeometry.drainScrollDelta(accumulated)
        XCTAssertEqual(firstFrame.emitted, 40)
        XCTAssertEqual(firstFrame.remaining, 120)

        let reverseFrame = RecallGeometry.drainScrollDelta(-95)
        XCTAssertEqual(reverseFrame.emitted, -40)
        XCTAssertEqual(reverseFrame.remaining, -55)
    }
}
