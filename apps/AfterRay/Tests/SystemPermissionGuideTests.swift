import XCTest
@testable import AfterRayApp

final class SystemPermissionGuideTests: XCTestCase {
    func testMissingMicrophoneDoesNotBlockOtherwiseGrantedPermissions() {
        XCTAssertTrue(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            microphoneUndetermined: true,
            hasMicrophoneInput: false,
            accessibility: true,
            recordsAudio: true
        ))
    }

    func testUnansweredMicrophonePromptStillBlocksWhenAudioIsEnabled() {
        XCTAssertFalse(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            microphoneUndetermined: true,
            hasMicrophoneInput: true,
            accessibility: true,
            recordsAudio: true
        ))
    }

    func testDeclinedMicrophoneDoesNotBlockStart() {
        XCTAssertTrue(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            microphoneUndetermined: false,
            hasMicrophoneInput: true,
            accessibility: true,
            recordsAudio: true
        ))
    }

    func testDeclinedMicrophoneStillRequiresScreenAndAccessibility() {
        XCTAssertFalse(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            microphoneUndetermined: false,
            hasMicrophoneInput: true,
            accessibility: false,
            recordsAudio: true
        ))
    }

    func testDisabledAudioDoesNotRequireAnAvailableMicrophone() {
        XCTAssertTrue(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            microphoneUndetermined: true,
            hasMicrophoneInput: true,
            accessibility: true,
            recordsAudio: false
        ))
    }

    func testMicrophoneGuideUsesTheExistingSystemSettingsEntry() {
        let guide = RequiredPermission.microphone.settingsGuide

        XCTAssertFalse(guide.allowsApplicationDrag)
        XCTAssertEqual(guide.title, "Turn on AfterRay for Microphone")
        XCTAssertEqual(guide.applicationAction, "Turn on the switch beside AfterRay")
    }

    func testManuallyAddablePermissionsKeepTheDragGuide() {
        for permission in [RequiredPermission.screenRecording, .accessibility] {
            XCTAssertTrue(permission.settingsGuide.allowsApplicationDrag)
            XCTAssertEqual(permission.settingsGuide.applicationAction, "Drag into System Settings")
        }
    }
}
