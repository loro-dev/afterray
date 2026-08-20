import AfterRayRecall
import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SystemPermissionCoordinator: ObservableObject {
    private static let automaticRequestLedgerKey =
        "dev.afterray.permissions.automatic-requested.v2"

    @Published private(set) var screenRecording = false
    @Published private(set) var microphone = false
    @Published private(set) var microphoneUndetermined = true
    @Published private(set) var hasMicrophoneInput = false
    @Published private(set) var accessibility = false
    @Published private(set) var isRequesting = false
    @Published private(set) var recordsAudio = AfterRayPreferences.recordAudio

    private let defaults: UserDefaults
    private let microphoneInputAvailable: () -> Bool
    private var preferenceObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        microphoneInputAvailable: @escaping () -> Bool = {
            AVCaptureDevice.default(for: .audio) != nil
        }
    ) {
        self.defaults = defaults
        self.microphoneInputAvailable = microphoneInputAvailable
        hasMicrophoneInput = microphoneInputAvailable()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .afterRayPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasRecordingAudio = self.recordsAudio
                self.recordsAudio = AfterRayPreferences.recordAudio
                // Turning audio on is the moment the user expects the mic
                // prompt; without a request AfterRay never appears in the
                // Microphone pane for them to grant.
                if !wasRecordingAudio, self.recordsAudio, !self.isRequesting {
                    self.hasMicrophoneInput = self.microphoneInputAvailable()
                    if self.microphoneRequired {
                        self.microphone = await self.resolveMicrophoneAuthorization()
                        self.microphoneUndetermined =
                            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                    }
                }
            }
        }
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    var allGranted: Bool {
        SystemPermissionPolicy.allGranted(
            screenRecording: screenRecording,
            microphone: microphone,
            microphoneUndetermined: microphoneUndetermined,
            hasMicrophoneInput: hasMicrophoneInput,
            accessibility: accessibility,
            recordsAudio: recordsAudio
        )
    }

    var microphoneRequired: Bool {
        SystemPermissionPolicy.microphoneRequired(
            recordsAudio: recordsAudio,
            hasMicrophoneInput: hasMicrophoneInput
        )
    }

    var microphoneDeclined: Bool {
        microphoneRequired && !microphone && !microphoneUndetermined
    }

    func requestInitialPermissionsOnce() async {
        guard !isRequesting else { return }
        refresh()
        guard !allGranted else { return }

        isRequesting = true
        defer { isRequesting = false }

        if !screenRecording, reserveAutomaticRequest(for: .screenRecording) {
            screenRecording = CGRequestScreenCaptureAccess()
        }

        if microphoneRequired {
            microphone = await resolveMicrophoneAuthorization()
        }

        if !accessibility, reserveAutomaticRequest(for: .accessibility) {
            requestAccessibilityAccess()
        }
        refresh()
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphone = microphoneStatus == .authorized
        microphoneUndetermined = microphoneStatus == .notDetermined
        hasMicrophoneInput = microphoneInputAvailable()
        accessibility = AXIsProcessTrusted()
    }

    /// Retries a permission only after an explicit user action. Automatic
    /// prompts stay guarded by the ledger above, while a permission removed in
    /// System Settings can still be requested again without reinstalling.
    func requestAgain(_ permission: RequiredPermission) async {
        refresh()
        switch permission {
        case .screenRecording:
            screenRecording = CGRequestScreenCaptureAccess()
        case .microphone:
            guard hasMicrophoneInput else { return }
            microphone = await resolveMicrophoneAuthorization()
        case .accessibility:
            requestAccessibilityAccess()
        }
        refresh()
    }

    func openSettings(for permission: RequiredPermission) {
        let anchor = switch permission {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// macOS lists an app under Privacy & Security → Microphone only once the
    /// consent prompt has been *answered*, so `.notDetermined` must always
    /// re-ask — never gate it behind the automatic-request ledger. Granting
    /// Screen Recording relaunches the app while the mic prompt is still open;
    /// a ledger entry written before the answer left installs that could never
    /// surface the prompt, or the Settings row, again.
    private func resolveMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func reserveAutomaticRequest(for permission: RequiredPermission) -> Bool {
        var requested = Set(
            defaults.stringArray(forKey: Self.automaticRequestLedgerKey) ?? []
        )
        guard requested.insert(permission.rawValue).inserted else { return false }
        defaults.set(requested.sorted(), forKey: Self.automaticRequestLedgerKey)
        return true
    }
}

enum PermissionGateFollowUp: Equatable {
    /// Native TCC alert was the grant path. Bring the overlay back.
    case returnToOverlay
    /// Screen Recording / Accessibility: open System Settings and show the
    /// drag card. Those TCC families have no in-place Allow/Don't Allow.
    case systemSettingsGuide
    /// Microphone already declined: deep-link to the Microphone pane without
    /// an instructional card that looks like an AfterRay toggle.
    case systemSettings
}

enum SystemPermissionPolicy {
    static func microphoneRequired(recordsAudio: Bool, hasMicrophoneInput: Bool) -> Bool {
        recordsAudio && hasMicrophoneInput
    }

    /// Screen Recording and Accessibility have no in-place grant, so the
    /// gate opens System Settings and shows the drag card. Microphone is
    /// standard TCC: `requestAccess` presents a native alert, and the app
    /// only appears in the Microphone pane after that alert is answered.
    /// Reusing the Settings overlay for the mic reads as a toggle on
    /// AfterRay itself. Already-denied recovery may deep-link to Settings
    /// with no instructional card.
    static func gateFollowUp(
        permission: RequiredPermission,
        granted: Bool,
        allGranted: Bool,
        microphoneWasUndetermined: Bool,
        microphoneDeclined: Bool
    ) -> PermissionGateFollowUp {
        if permission == .microphone {
            if !granted, microphoneDeclined, !microphoneWasUndetermined {
                return .systemSettings
            }
            return .returnToOverlay
        }
        if granted || allGranted {
            return .returnToOverlay
        }
        return .systemSettingsGuide
    }

    /// A declined microphone is an answer, not a blocker: capture proceeds
    /// with screen and system audio (the shim skips the microphone stream).
    /// Only an unanswered (`.notDetermined`) prompt holds the gate, so nobody
    /// starts recording before macOS has had the chance to ask.
    static func allGranted(
        screenRecording: Bool,
        microphone: Bool,
        microphoneUndetermined: Bool,
        hasMicrophoneInput: Bool,
        accessibility: Bool,
        recordsAudio: Bool
    ) -> Bool {
        screenRecording
            && accessibility
            && (microphone
                || !microphoneRequired(
                    recordsAudio: recordsAudio,
                    hasMicrophoneInput: hasMicrophoneInput
                )
                || !microphoneUndetermined)
    }
}

enum RequiredPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case accessibility

    var id: String { rawValue }

    var title: String { title(.english) }

    func title(_ copy: AfterRayCopy) -> String {
        switch self {
        case .screenRecording: copy.permissions.screenAndSystemAudio
        case .microphone: copy.permissions.microphone
        case .accessibility: copy.permissions.accessibility
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        }
    }

    var isGrantedNow: Bool {
        switch self {
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            AXIsProcessTrusted()
        }
    }

    /// Screen Recording and Accessibility need System Settings; microphone
    /// is granted (or declined) by the native TCC alert.
    var opensSystemSettingsGuide: Bool {
        switch self {
        case .microphone: false
        case .screenRecording, .accessibility: true
        }
    }

    var settingsGuide: PermissionSettingsGuideContent {
        settingsGuide(copy: .english)
    }

    func settingsGuide(copy: AfterRayCopy) -> PermissionSettingsGuideContent {
        PermissionSettingsGuideContent(
            title: copy.permissions.addTo(title(copy)),
            instructions: copy.permissions.dragInstructions,
            applicationAction: copy.permissions.dragIntoSettings,
            actionIcon: "hand.draw",
            allowsApplicationDrag: true
        )
    }
}

struct PermissionSettingsGuideContent: Equatable {
    let title: String
    let instructions: String
    let applicationAction: String
    let actionIcon: String
    let allowsApplicationDrag: Bool
}
