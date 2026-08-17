import XCTest
@testable import AfterRayApp

final class SystemPermissionGuideTests: XCTestCase {
    func testMissingMicrophoneDoesNotBlockOtherwiseGrantedPermissions() {
        XCTAssertTrue(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            hasMicrophoneInput: false,
            accessibility: true,
            recordsAudio: true
        ))
    }

    func testAvailableMicrophoneStillRequiresAuthorizationWhenAudioIsEnabled() {
        XCTAssertFalse(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
            hasMicrophoneInput: true,
            accessibility: true,
            recordsAudio: true
        ))
    }

    func testDisabledAudioDoesNotRequireAnAvailableMicrophone() {
        XCTAssertTrue(SystemPermissionPolicy.allGranted(
            screenRecording: true,
            microphone: false,
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
