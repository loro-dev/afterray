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
    @Published private(set) var accessibility = false
    @Published private(set) var isRequesting = false
    @Published private(set) var recordsAudio = AfterRayPreferences.recordAudio

    private let defaults: UserDefaults
    private var preferenceObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .afterRayPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recordsAudio = AfterRayPreferences.recordAudio
            }
        }
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    var allGranted: Bool {
        screenRecording && accessibility && (microphone || !recordsAudio)
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

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = true
        case .notDetermined where reserveAutomaticRequest(for: .microphone):
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        case .notDetermined, .denied, .restricted:
            microphone = false
        @unknown default:
            microphone = false
        }

        if !accessibility, reserveAutomaticRequest(for: .accessibility) {
            requestAccessibilityAccess()
        }
        refresh()
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
    }

    /// Retries a permission only after an explicit user action. Automatic
    /// prompts stay guarded by the ledger above, while a permission removed in
    /// System Settings can still be requested again without reinstalling.
    func requestAgain(_ permission: RequiredPermission) async {
        switch permission {
        case .screenRecording:
            screenRecording = CGRequestScreenCaptureAccess()
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                microphone = await AVCaptureDevice.requestAccess(for: .audio)
            }
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
