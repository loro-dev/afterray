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
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

enum SystemPermissionPolicy {
    static func microphoneRequired(recordsAudio: Bool, hasMicrophoneInput: Bool) -> Bool {
        recordsAudio && hasMicrophoneInput
    }

    static func allGranted(
        screenRecording: Bool,
        microphone: Bool,
        hasMicrophoneInput: Bool,
        accessibility: Bool,
        recordsAudio: Bool
    ) -> Bool {
        screenRecording
            && accessibility
            && (!microphoneRequired(
                recordsAudio: recordsAudio,
                hasMicrophoneInput: hasMicrophoneInput
            ) || microphone)
    }
}

enum RequiredPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
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

    var settingsGuide: PermissionSettingsGuideContent {
        switch self {
        case .microphone:
            PermissionSettingsGuideContent(
                title: "Turn on AfterRay for Microphone",
                instructions: "Microphone access can't be added by dragging. Turn on AfterRay in the list.",
                applicationAction: "Turn on the switch beside AfterRay",
                actionIcon: "checkmark.circle",
                allowsApplicationDrag: false
            )
        case .screenRecording, .accessibility:
            PermissionSettingsGuideContent(
                title: "Add AfterRay to \(title)",
                instructions: "Drag the application below into the list in System Settings, then turn it on.",
                applicationAction: "Drag into System Settings",
                actionIcon: "hand.draw",
                allowsApplicationDrag: true
            )
        }
    }
}

struct PermissionSettingsGuideContent: Equatable {
    let title: String
    let instructions: String
    let applicationAction: String
    let actionIcon: String
    let allowsApplicationDrag: Bool
}
