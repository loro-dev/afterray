import XCTest
@testable import AfterRayApp

final class SystemPermissionGuideTests: XCTestCase {
    func testBootstrapRequestsOnlyRequiredSystemSettingsPermissions() {
        XCTAssertTrue(SystemPermissionPolicy.shouldRequestAutomatically(.screenRecording))
        XCTAssertTrue(SystemPermissionPolicy.shouldRequestAutomatically(.accessibility))
        XCTAssertFalse(SystemPermissionPolicy.shouldRequestAutomatically(.microphone))
    }

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

    func testMicrophoneDoesNotOpenTheSystemSettingsGuide() {
        XCTAssertFalse(RequiredPermission.microphone.opensSystemSettingsGuide)
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .microphone,
                granted: false,
                allGranted: false,
                microphoneWasUndetermined: true,
                microphoneDeclined: false
            ),
            .returnToOverlay
        )
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .microphone,
                granted: false,
                allGranted: false,
                microphoneWasUndetermined: true,
                microphoneDeclined: true
            ),
            .returnToOverlay
        )
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .microphone,
                granted: true,
                allGranted: false,
                microphoneWasUndetermined: true,
                microphoneDeclined: false
            ),
            .returnToOverlay
        )
    }

    func testDeclinedMicrophoneRecoveryOpensSettingsWithoutTheGuideCard() {
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .microphone,
                granted: false,
                allGranted: false,
                microphoneWasUndetermined: false,
                microphoneDeclined: true
            ),
            .systemSettings
        )
    }

    func testManuallyAddablePermissionsKeepTheDragGuide() {
        for permission in [RequiredPermission.screenRecording, .accessibility] {
            XCTAssertTrue(permission.opensSystemSettingsGuide)
            XCTAssertTrue(permission.settingsGuide.allowsApplicationDrag)
            XCTAssertEqual(permission.settingsGuide.applicationAction, "Drag into System Settings")
            XCTAssertEqual(
                SystemPermissionPolicy.gateFollowUp(
                    permission: permission,
                    granted: false,
                    allGranted: false,
                    microphoneWasUndetermined: false,
                    microphoneDeclined: false
                ),
                .systemSettingsGuide
            )
        }
    }

    func testGrantedOrCompleteGateReturnsToTheOverlay() {
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .screenRecording,
                granted: true,
                allGranted: false,
                microphoneWasUndetermined: false,
                microphoneDeclined: false
            ),
            .returnToOverlay
        )
        XCTAssertEqual(
            SystemPermissionPolicy.gateFollowUp(
                permission: .accessibility,
                granted: false,
                allGranted: true,
                microphoneWasUndetermined: false,
                microphoneDeclined: true
            ),
            .returnToOverlay
        )
    }
}
