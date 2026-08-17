@testable import AfterRayCapturePolicy
import XCTest

final class AudioCapturePlanTests: XCTestCase {
    func testMissingMicrophoneKeepsSystemAudioEnabled() {
        let plan = AudioCapturePlan(recordsAudio: true, hasMicrophoneInput: false)

        XCTAssertTrue(plan.capturesSystemAudio)
        XCTAssertFalse(plan.capturesMicrophone)
    }

    func testAvailableMicrophoneEnablesBothAudioStreams() {
        let plan = AudioCapturePlan(recordsAudio: true, hasMicrophoneInput: true)

        XCTAssertTrue(plan.capturesSystemAudio)
        XCTAssertTrue(plan.capturesMicrophone)
    }

    func testDisabledAudioDisablesBothAudioStreams() {
        let plan = AudioCapturePlan(recordsAudio: false, hasMicrophoneInput: true)

        XCTAssertFalse(plan.capturesSystemAudio)
        XCTAssertFalse(plan.capturesMicrophone)
    }
}
