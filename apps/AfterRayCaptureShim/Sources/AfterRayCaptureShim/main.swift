@preconcurrency import AVFoundation
import AfterRayCapturePolicy
import ApplicationServices
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private let afterRayAppBundleIdentifier = "dev.afterray.app"

private func hardenPrivateFile(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: url.path
    )
}

private func hardenPrivateDirectory(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
}

private struct Options {
    let outputDirectory: URL
    let audioSegmentSeconds: Double
    let jpegQuality: Double
    let recordAudio: Bool

    static func parse(_ arguments: [String]) throws -> Self {
        var outputDirectory: URL?
        var audioSegmentSeconds = 300.0
        var jpegQuality = 0.95
        var recordAudio = true
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--no-audio" {
                recordAudio = false
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw ShimError.invalidArguments("missing value for \(key)")
            }
            let value = arguments[index + 1]
            switch key {
            case "--output-dir":
                outputDirectory = URL(fileURLWithPath: value, isDirectory: true)
            case "--audio-segment-seconds":
                guard let parsed = Double(value), parsed > 0 else {
                    throw ShimError.invalidArguments("audio segment duration must be positive")
                }
                audioSegmentSeconds = parsed
            case "--jpeg-quality":
                guard let parsed = Double(value), (0 ... 1).contains(parsed) else {
                    throw ShimError.invalidArguments("JPEG quality must be between zero and one")
                }
                jpegQuality = parsed
            default:
                throw ShimError.invalidArguments("unknown option \(key)")
            }
            index += 2
        }
        guard let outputDirectory else {
            throw ShimError.invalidArguments("--output-dir is required")
        }
        return Self(
            outputDirectory: outputDirectory,
            audioSegmentSeconds: audioSegmentSeconds,
            jpegQuality: jpegQuality,
            recordAudio: recordAudio
        )
    }
}

private enum ShimError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case noDisplay
    case imageEncoding

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .noDisplay: "ScreenCaptureKit did not return a display"
        case .imageEncoding: "AppKit could not encode the screenshot"
        }
    }
}

private enum ArtifactKind: String, Encodable {
    case screen
    case systemAudio = "system_audio"
    case microphone
    case accessibility
    /// An R3 edge snapshot: the same accessibility payload, walked because the
    /// user changed scope rather than because the heartbeat came round, and
    /// deliberately unpaired with any screenshot.
    case accessibilityEdge = "accessibility_edge"
}

private struct Event: Encodable {
    let event: String
    var kind: ArtifactKind?
    var path: String?
    var contentType: String?
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    var byteCount: UInt64?
    var requestId: String?
    var displayId: UInt32?
    var width: Int?
    var height: Int?
    var code: String?
    var message: String?
    var inputRecords: [InputEventRecord]?
    var droppedInputs: Int?

    enum CodingKeys: String, CodingKey {
        case event, kind, path, code, message
        case contentType = "content_type"
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case byteCount = "byte_count"
        case requestId = "request_id"
        case displayId = "display_id"
        case width, height
        case inputRecords = "events"
        case droppedInputs = "dropped"
    }

    static func ready(display: SCDisplay) -> Self {
        Self(event: "ready", displayId: display.displayID, width: display.width, height: display.height)
    }

    static func artifact(
        kind: ArtifactKind,
        url: URL,
        startedAtMs: Int64,
        endedAtMs: Int64,
        requestId: String? = nil
    ) -> Self {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let contentType: String
        switch kind {
        case .screen: contentType = "image/jpeg"
        case .systemAudio, .microphone: contentType = "audio/mp4"
        case .accessibility, .accessibilityEdge: contentType = "application/vnd.afterray.ax+json"
        }
        return Self(
            event: "artifact",
            kind: kind,
            path: url.path,
            contentType: contentType,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            byteCount: size,
            requestId: requestId
        )
    }

    static func warning(code: String, message: String) -> Self {
        Self(event: "warning", code: code, message: message)
    }

    static func failed(code: String, message: String) -> Self {
        Self(event: "failed", code: code, message: message)
    }

    static let stopped = Self(event: "stopped")

    static func inputEvents(_ records: [InputEventRecord], dropped: Int) -> Self {
        var event = Self(event: "input_events")
        event.inputRecords = records
        event.droppedInputs = dropped > 0 ? dropped : nil
        return event
    }

    init(
        event: String,
        kind: ArtifactKind? = nil,
        path: String? = nil,
        contentType: String? = nil,
        startedAtMs: Int64? = nil,
        endedAtMs: Int64? = nil,
        byteCount: UInt64? = nil,
        requestId: String? = nil,
        displayId: UInt32? = nil,
        width: Int? = nil,
        height: Int? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.event = event
        self.kind = kind
        self.path = path
        self.contentType = contentType
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.byteCount = byteCount
        self.requestId = requestId
        self.displayId = displayId
        self.width = width
        self.height = height
        self.code = code
        self.message = message
    }
}

private struct AccessibilityFrame: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct AccessibilityNode: Encodable {
    let role: String?
    let subrole: String?
    let title: String?
    let nodeDescription: String?
    let identifier: String?
    let value: String?
    let valueRedacted: Bool
    let url: String?
    let document: String?
    let frame: AccessibilityFrame?
    let children: [AccessibilityNode]

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, identifier, value, url, document, frame, children
        case nodeDescription = "description"
        case valueRedacted = "value_redacted"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(nodeDescription, forKey: .nodeDescription)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(valueRedacted, forKey: .valueRedacted)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(document, forKey: .document)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encode(children, forKey: .children)
    }

}

private struct AccessibilitySnapshot: Encodable {
    let capturedAtMs: Int64
    let processId: Int32
    let bundleIdentifier: String?
    let applicationName: String?
    let windowTitle: String?
    let url: String?
    let document: String?
    let privateBrowsing: Bool
    let truncated: Bool
    let digest: AccessibilityDigest
    let root: AccessibilityNode

    enum CodingKeys: String, CodingKey {
        case capturedAtMs = "captured_at_ms"
        case processId = "process_id"
        case bundleIdentifier = "bundle_identifier"
        case applicationName = "application_name"
        case windowTitle = "window_title"
        case url, document, truncated, digest, root
        case privateBrowsing = "private_browsing"
    }
}

private struct AccessibilityDigest: Encodable {
    let applicationName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let url: String?
    let document: String?
    let focusedRole: String?
    let focusedTitle: String?
    let focusedValue: String?
    let selectedText: String?
    let headings: [String]
    let visibleText: [String]

    enum CodingKeys: String, CodingKey {
        case url, document, headings
        case applicationName = "application_name"
        case bundleIdentifier = "bundle_identifier"
        case windowTitle = "window_title"
        case focusedRole = "focused_role"
        case focusedTitle = "focused_title"
        case focusedValue = "focused_value"
        case selectedText = "selected_text"
        case visibleText = "visible_text"
    }
}

private final class AccessibilityTreeEncoder {
    private let maximumNodes = 20_000
    /// Whole-walk wall-clock budget. Every AX attribute read is synchronous
    /// IPC into the target app's main thread; without a deadline one busy
    /// Electron process can stall a tick for seconds while also lagging the
    /// very app the user is working in. Overrun sets `truncated`, exactly
    /// like the node cap. The per-call bound that makes this deadline real
    /// is the process-global messaging timeout set at startup.
    private let walkDeadline = ContinuousClock.now + .milliseconds(500)
    private var nodeCount = 0
    private var visited = Set<CFHashCode>()
    private(set) var truncated = false
    private(set) var url: String?
    private(set) var document: String?
    private(set) var windowTitle: String?
    private var foundWebURL = false
    private var focusedRole: String?
    private var focusedTitle: String?
    private var focusedValue: String?
    private var selectedText: String?
    private var headings: [String] = []
    private var visibleTexts: [String] = []

    func encode(_ element: AXUIElement) -> AccessibilityNode {
        nodeCount += 1
        let identity = CFHash(element)
        guard nodeCount <= maximumNodes,
            ContinuousClock.now < walkDeadline,
            visited.insert(identity).inserted
        else {
            truncated = true
            return AccessibilityNode(
                role: string(element, kAXRoleAttribute),
                subrole: string(element, kAXSubroleAttribute),
                title: nil,
                nodeDescription: nil,
                identifier: nil,
                value: nil,
                valueRedacted: false,
                url: nil,
                document: nil,
                frame: nil,
                children: []
            )
        }

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        // The menu bar is most of the walk in native apps (measured: 205 of
        // 257 nodes in Ghostty, 245 of 276 in Zed, ~170 of 1115 in Feishu)
        // and no consumer reads it: digests collect text roles only, the
        // store's text extraction treats menus as chrome, and exclusion
        // checks use app identity. Stub it instead of descending. This is
        // deliberately not `truncated` — nothing of value was cut. An open
        // menu-bar menu is skipped with it; a 10s heartbeat rarely lands on
        // one and menu labels are chrome either way.
        if role == "AXMenuBar" {
            return AccessibilityNode(
                role: role,
                subrole: subrole,
                title: nil,
                nodeDescription: nil,
                identifier: nil,
                value: nil,
                valueRedacted: false,
                url: nil,
                document: nil,
                frame: nil,
                children: []
            )
        }
        let secure = subrole == "AXSecureTextField"
        let title = string(element, kAXTitleAttribute)
        let nodeDescription = string(element, kAXDescriptionAttribute)
        let identifier = string(element, kAXIdentifierAttribute)
        let value = secure ? nil : scalarString(attribute(element, kAXValueAttribute))
        let nodeURL = secure ? nil : firstLocation(element, Self.urlAttributeNames)
        let nodeDocument = secure ? nil : normalizedDocument(firstLocation(element, Self.documentAttributeNames))
        considerActivityContext(role: role, title: title, url: nodeURL, document: nodeDocument)
        considerDigest(
            element: element,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            focused: boolValue(element, kAXFocusedAttribute)
        )
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .map(encode)
        return AccessibilityNode(
            role: role,
            subrole: subrole,
            title: title,
            nodeDescription: nodeDescription,
            identifier: identifier,
            value: value,
            valueRedacted: secure,
            url: nodeURL.flatMap(classifiedURL),
            document: nodeDocument,
            frame: frame(element),
            children: children
        )
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        scalarString(attribute(element, name))
    }

    private func scalarString(_ value: AnyObject?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static let urlAttributeNames = [
        kAXURLAttribute as String,
        "AXURL",
        "URL",
        "AXAddress",
    ]
    private static let documentAttributeNames = [
        kAXDocumentAttribute as String,
        "AXDocument",
        "Document",
    ]

    func digest(
        applicationName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        privateBrowsing: Bool
    ) -> AccessibilityDigest {
        AccessibilityDigest(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle ?? self.windowTitle,
            url: BrowserPrivacyDetector.redactedURL(url, privateBrowsing: privateBrowsing),
            document: document,
            focusedRole: focusedRole,
            focusedTitle: focusedTitle,
            focusedValue: BrowserPrivacyDetector.redactedBrowserChromeValue(
                focusedValue,
                role: focusedRole,
                insideWebContent: false,
                privateBrowsing: privateBrowsing
            ),
            selectedText: selectedText,
            headings: headings,
            visibleText: privateBrowsing
                ? visibleTexts.filter { !BrowserPrivacyDetector.looksLikeWebLocation($0) }
                : visibleTexts
        )
    }

    private func considerDigest(
        element: AXUIElement,
        role: String?,
        subrole: String?,
        title: String?,
        value: String?,
        focused: Bool
    ) {
        if focused, focusedRole == nil {
            focusedRole = nonempty(role)
            focusedTitle = nonempty(title)
            focusedValue = nonempty(value).map { clip($0, 280) }
            selectedText = nonempty(string(element, kAXSelectedTextAttribute as String))
        }
        if (role == "AXHeading" || subrole == "AXHeading"), headings.count < 8,
           let heading = nonempty(title) ?? nonempty(value)
        {
            appendUnique(&headings, clip(heading, 80), limit: 8)
        }
        if ["AXStaticText", "AXTextField", "AXTextArea", "AXLink"].contains(role ?? ""),
           let text = nonempty(title) ?? nonempty(value)
        {
            appendUnique(&visibleTexts, clip(text, 80), limit: 16)
        }
    }

    private func boolValue(_ element: AXUIElement, _ name: String) -> Bool {
        guard let number = attribute(element, name) as? NSNumber else { return false }
        return number.boolValue
    }

    private func considerActivityContext(role: String?, title: String?, url: String?, document: String?) {
        if windowTitle == nil, isWindowRole(role), let title, !title.isEmpty {
            windowTitle = title
        }
        if let url {
            if looksLikeFileLocation(url) {
                if self.document == nil {
                    self.document = normalizedDocument(url)
                }
            } else if isDocumentLikeRole(role) {
                if !foundWebURL {
                    self.url = url
                    foundWebURL = true
                }
            } else if self.url == nil {
                self.url = url
            }
        }
        if self.document == nil, let document {
            self.document = document
        }
    }

    private func firstLocation(_ element: AXUIElement, _ names: [String]) -> String? {
        for name in names {
            if let value = locationString(attribute(element, name)) {
                return value
            }
        }
        return nil
    }

    private func locationString(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let url = value as? URL {
            return nonempty(url.absoluteString)
        }
        if let url = value as? NSURL {
            return nonempty(url.absoluteString)
        }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return nonempty((value as! CFURL as URL).absoluteString)
        }
        return nonempty(scalarString(value))
    }

    private func classifiedURL(_ value: String) -> String? {
        looksLikeFileLocation(value) ? nil : nonempty(value)
    }

    private func frame(_ element: AXUIElement) -> AccessibilityFrame? {
        guard let frame = accessibilityFrame(element) else { return nil }
        return AccessibilityFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }
}

private func isWindowRole(_ role: String?) -> Bool {
    role == "AXWindow" || role == "AXStandardWindow"
}

private func isDocumentLikeRole(_ role: String?) -> Bool {
    role == "AXWebArea" || role == "AXBrowser" || role == "AXWebDocument" || role == "AXDocument"
}

private func looksLikeFileLocation(_ value: String) -> Bool {
    value.hasPrefix("file://") || (value.hasPrefix("/") && !value.hasPrefix("//"))
}

private func normalizedDocument(_ value: String?) -> String? {
    guard let value = nonempty(value) else { return nil }
    if value.hasPrefix("http://") || value.hasPrefix("https://") { return nil }
    if value.hasPrefix("file://") { return value }
    if value.hasPrefix("/") {
        return URL(fileURLWithPath: value).absoluteString
    }
    return value
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func clip(_ value: String, _ limit: Int) -> String {
    if value.count <= limit { return value }
    return String(value.prefix(max(limit - 1, 1))) + "…"
}

private func appendUnique(_ items: inout [String], _ value: String, limit: Int) {
    guard items.count < limit, !items.contains(value) else { return }
    items.append(value)
}

private enum AccessibilityCapture {
    case artifact(URL, context: ForegroundCaptureContext)
    case privateBrowsing(BrowserPrivacyEvidence)
    case foregroundChanged
}

private struct ForegroundCaptureContext {
    let processId: pid_t
    let windowId: CGWindowID?
    let windowFrame: CGRect?
}

private enum BrowserAutomationProbe {
    private static let timeout: TimeInterval = 1.0

    static func query(bundleIdentifier: String?) async -> BrowserPrivacyState {
        guard let query = BrowserPrivacyAutomationQuery.make(bundleIdentifier: bundleIdentifier) else {
            return .unknown
        }
        return await Task.detached(priority: .utility) {
            guard requestPermission(bundleIdentifier: query.bundleIdentifier) else {
                return .unknown
            }
            return run(query)
        }.value
    }

    private static func requestPermission(bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let address = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(
            address,
            typeWildCard,
            typeWildCard,
            true
        ) == noErr
    }

    private static func run(_ query: BrowserPrivacyAutomationQuery) -> BrowserPrivacyState {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", query.script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unknown
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return .unknown
        }
        guard process.terminationStatus == 0 else { return .unknown }

        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return .unknown }
        return query.parse(output: output)
    }
}

/// Reads only browser-owned Accessibility chrome. Document-like subtrees are
/// never entered, so a private page's URL and content cannot be materialized
/// while looking for a positive fallback marker.
private func browserChromePrivacyState(
    browserWindow: AXUIElement,
    bundleIdentifier: String?,
    automationState: BrowserPrivacyState,
    windowTitle: String?
) -> BrowserPrivacyState {
    var detector = BrowserPrivacyDetector(bundleIdentifier: bundleIdentifier)
    guard detector.isKnownBrowser else {
        return detector.resolve(
            automationState: automationState,
            windowTitle: windowTitle
        )
    }

    var nodeCount = 0
    var visited = Set<CFHashCode>()
    let maximumNodes = 20_000

    func walk(_ element: AXUIElement, insideBrowserWindow: Bool) {
        guard nodeCount < maximumNodes, visited.insert(CFHash(element)).inserted else { return }
        nodeCount += 1

        let role = axString(element, kAXRoleAttribute)
        if isDocumentLikeRole(role) { return }
        let nodeIsInsideBrowserWindow = insideBrowserWindow || isWindowRole(role)
        detector.observe(
            role: role,
            title: axString(element, kAXTitleAttribute),
            nodeDescription: axString(element, kAXDescriptionAttribute),
            identifier: axString(element, kAXIdentifierAttribute),
            insideBrowserWindow: nodeIsInsideBrowserWindow,
            insideWebContent: false
        )
        let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children {
            walk(child, insideBrowserWindow: nodeIsInsideBrowserWindow)
        }
    }

    walk(browserWindow, insideBrowserWindow: true)
    return detector.resolve(
        automationState: automationState,
        windowTitle: windowTitle
    )
}

private func captureAccessibilityTree(
    capturedAtMs: Int64,
    outputDirectory: URL,
    events: EventWriter
) async throws -> AccessibilityCapture? {
    guard let application = capturedForegroundApplication() else {
        events.send(.warning(code: "ax_no_frontmost_app", message: "No foreground application was available"))
        return nil
    }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    let preflightDetector = BrowserPrivacyDetector(bundleIdentifier: application.bundleIdentifier)
    let foregroundWindow = frontWindowElement(appElement)
    let browserWindow = preflightDetector.isKnownBrowser ? foregroundWindow : nil
    let windowId = cgFrontWindowId(for: application.processIdentifier)
    let windowFrame = foregroundWindow.flatMap(accessibilityFrame)
    let context: ForegroundCaptureContext
    let captureRoot: AXUIElement
    if preflightDetector.isKnownBrowser {
        guard
            let browserWindow,
            let windowId
        else { return .foregroundChanged }
        context = ForegroundCaptureContext(
            processId: application.processIdentifier,
            windowId: windowId,
            windowFrame: windowFrame
        )
        captureRoot = browserWindow
    } else {
        context = ForegroundCaptureContext(
            processId: application.processIdentifier,
            windowId: windowId,
            windowFrame: windowFrame
        )
        captureRoot = appElement
    }
    let windowTitle = frontWindowTitle(
        appElement: appElement,
        processId: application.processIdentifier,
        treeTitle: nil
    )
    var privacyState = preflightDetector.resolve(windowTitle: windowTitle)
    if case let .privateBrowsing(evidence) = privacyState {
        log("skipping private browser capture evidence=\(evidence.rawValue)")
        return .privateBrowsing(evidence)
    }

    let automationState = await BrowserAutomationProbe.query(
        bundleIdentifier: application.bundleIdentifier
    )
    guard foregroundCaptureContextIsCurrent(context) else {
        return .foregroundChanged
    }
    privacyState = preflightDetector.resolve(
        automationState: automationState,
        windowTitle: windowTitle
    )
    if case let .privateBrowsing(evidence) = privacyState {
        log("skipping private browser capture evidence=\(evidence.rawValue)")
        return .privateBrowsing(evidence)
    }

    privacyState = browserChromePrivacyState(
        browserWindow: captureRoot,
        bundleIdentifier: application.bundleIdentifier,
        automationState: automationState,
        windowTitle: windowTitle
    )
    if case let .privateBrowsing(evidence) = privacyState {
        log("skipping private browser capture evidence=\(evidence.rawValue)")
        return .privateBrowsing(evidence)
    }

    let encoder = AccessibilityTreeEncoder()
    let encodedRoot = encoder.encode(captureRoot)
    let privateBrowsing = false
    let snapshot = AccessibilitySnapshot(
        capturedAtMs: capturedAtMs,
        processId: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier,
        applicationName: application.localizedName,
        windowTitle: windowTitle ?? encoder.windowTitle,
        url: BrowserPrivacyDetector.redactedURL(encoder.url, privateBrowsing: privateBrowsing),
        document: encoder.document,
        privateBrowsing: privateBrowsing,
        truncated: encoder.truncated,
        digest: encoder.digest(
            applicationName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: windowTitle ?? encoder.windowTitle,
            privateBrowsing: privateBrowsing
        ),
        root: encodedRoot
    )
    guard foregroundCaptureContextIsCurrent(context) else {
        return .foregroundChanged
    }
    let url = outputDirectory
        .appendingPathComponent("accessibility-\(UUID().uuidString)")
        .appendingPathExtension("json")
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    try hardenPrivateFile(url)
    return .artifact(url, context: context)
}

private func capturedForegroundApplication() -> NSRunningApplication? {
    if
        let frontmost = NSWorkspace.shared.frontmostApplication,
        frontmost.bundleIdentifier != afterRayAppBundleIdentifier
    {
        return frontmost
    }

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for window in windows {
        guard
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let processId = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let application = NSRunningApplication(processIdentifier: processId),
            application.bundleIdentifier != afterRayAppBundleIdentifier,
            application.activationPolicy == .regular
        else { continue }
        return application
    }
    return nil
}

private func frontWindowTitle(appElement: AXUIElement, processId: pid_t, treeTitle: String?) -> String? {
    if let frontWindow = frontWindowElement(appElement),
       let title = nonempty(axString(frontWindow, kAXTitleAttribute))
    {
        return title
    }
    if let treeTitle { return treeTitle }
    return cgWindowName(for: processId)
}

private func frontWindowElement(_ appElement: AXUIElement) -> AXUIElement? {
    axElement(appElement, kAXFocusedWindowAttribute)
        ?? axElement(appElement, kAXMainWindowAttribute)
}

private func axAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func axString(_ element: AXUIElement, _ name: String) -> String? {
    axAttribute(element, name) as? String
}

private func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    axAttribute(element, name).map { $0 as! AXUIElement }
}

private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
    guard
        let positionValue = axAttribute(element, kAXPositionAttribute),
        let sizeValue = axAttribute(element, kAXSizeAttribute),
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

private func cgFrontWindowInfo(for processId: pid_t) -> [String: Any]? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for window in windows {
        guard
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processId,
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        else { continue }
        return window
    }
    return nil
}

private func cgFrontWindowId(for processId: pid_t) -> CGWindowID? {
    (cgFrontWindowInfo(for: processId)?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
}

private func cgWindowName(for processId: pid_t) -> String? {
    nonempty(cgFrontWindowInfo(for: processId)?[kCGWindowName as String] as? String)
}

private func foregroundCaptureContextIsCurrent(_ context: ForegroundCaptureContext) -> Bool {
    guard let application = capturedForegroundApplication(),
          application.processIdentifier == context.processId
    else { return false }
    if let windowId = context.windowId,
       cgFrontWindowId(for: context.processId) != windowId
    {
        return false
    }
    guard let windowFrame = context.windowFrame else { return true }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let currentWindow = frontWindowElement(appElement),
          let currentWindowFrame = accessibilityFrame(currentWindow)
    else { return false }
    return currentWindowFrame == windowFrame
}

private final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    func send(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private struct SendableAssetWriter: @unchecked Sendable {
    let value: AVAssetWriter
}

/// Keeps an excluded app's audio off disk while it is frontmost.
///
/// A screenshot can be deleted after the fact, because the accessibility
/// snapshot that names the app arrives right behind it. Audio has no such
/// snapshot, and a finished `m4a` segment covers five minutes that cannot be
/// sliced apart afterwards — so the only place the exclusion can be honoured
/// is here, before a sample buffer reaches the writer.
///
/// The frontmost app is polled rather than observed: the shim's main thread
/// sits blocked in `readLine` between commands and never services a run loop,
/// so `NSWorkspace` activation notifications would not be delivered. It reads
/// the same source the capture path already trusts (`main.swift:781`).
///
/// Polling alone would still leak, in two ways: the stream starts delivering
/// audio before the daemon's list has been read off stdin, and a switch into
/// an excluded app is noticed up to one interval late. So this gate does not
/// answer "is an excluded app in front *now*" — it answers "which stretch of
/// the recent past is known to have had none". Samples are held until a check
/// vouches for the moment they were recorded, and are dropped otherwise. No
/// sample from an unvouched-for moment is ever handed to a writer.
private final class ExcludedAudioGate: @unchecked Sendable {
    /// Audio is held for up to this long before it can be written, so this is
    /// added latency on a five-minute segment, not exposure.
    private static let pollInterval = DispatchTimeInterval.milliseconds(100)

    /// What the checks so far establish about the foreground.
    enum Foreground {
        /// The most recent check found an excluded app in front.
        case excluded
        /// Every check from `from` through `through` (uptime nanoseconds)
        /// found no excluded app, so a sample that arrived inside that span
        /// was recorded while none was in front.
        case clear(from: UInt64, through: UInt64)
        /// Nothing is established yet: either the daemon's list has not
        /// arrived, or no check has run since an excluded app was in front.
        case unknown
    }

    private let lock = NSLock()
    /// `nil` until the daemon sends the list. An app in front before that
    /// point cannot be judged — it may well be one the user excluded — so
    /// this is what keeps the startup window closed.
    private var excluded: Set<String>?
    private var foreground: Foreground = .unknown
    private var timer: DispatchSourceTimer?

    var state: Foreground {
        lock.lock()
        defer { lock.unlock() }
        return foreground
    }

    /// Verdict for input-event suppression: `nil` until the daemon's list
    /// has arrived, or when the frontmost app is unknown — both fail closed,
    /// the same startup posture the audio hold takes.
    func excludedVerdict(for bundleId: String?) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let excluded, let bundleId else { return nil }
        return excluded.contains(bundleId.lowercased())
    }

    /// The daemon sends the list once at startup and again on every change.
    func setExcludedBundles(_ bundleIds: [String]) {
        let normalized = Set(bundleIds.map { $0.lowercased() })
        lock.lock()
        excluded = normalized
        lock.unlock()
        refresh()
    }

    func start(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    private func refresh() {
        lock.lock()
        let excluded = self.excluded
        lock.unlock()
        // Before the list arrives the foreground stays unknown, and held
        // audio stays held.
        guard let excluded else { return }
        // Nothing excluded is the common case; skip the AppKit query entirely.
        let frontmost = excluded.isEmpty
            ? nil
            : NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let isExcluded = frontmost.map(excluded.contains) ?? false
        let now = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        defer { lock.unlock() }
        guard !isExcluded else {
            if case .excluded = foreground {} else {
                log("audio suppressed for \(frontmost ?? "an excluded app")")
            }
            foreground = .excluded
            return
        }
        if case let .clear(from, _) = foreground {
            // Extend the run: everything from `from` to now is vouched for.
            foreground = .clear(from: from, through: now)
        } else {
            // First clear check after startup or after an excluded stretch.
            // The run starts here; nothing recorded earlier can be vouched for.
            if case .excluded = foreground {
                log("audio resumed after \(frontmost ?? "an excluded app")")
            }
            foreground = .clear(from: now, through: now)
        }
    }
}

private final class AudioSegmentWriter {
    private let kind: ArtifactKind
    private let outputDirectory: URL
    private let segmentDuration: Double
    private let events: EventWriter
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedAt: CMTime?
    private var startedAtMs: Int64?
    private var outputURL: URL?
    /// Samples wait here until a foreground check vouches for the moment they
    /// were recorded. Nothing reaches the file before that.
    private var pending: [(arrivedAt: UInt64, buffer: CMSampleBuffer)] = []

    /// If confirmation never comes — the daemon never sent a list, or the poll
    /// stalled — the oldest samples are dropped rather than held forever. At
    /// roughly one buffer per 20 ms this is over a second of slack against a
    /// 100 ms poll, and what it drops is audio nothing can vouch for anyway.
    private static let maximumPending = 64

    init(kind: ArtifactKind, outputDirectory: URL, segmentDuration: Double, events: EventWriter) {
        self.kind = kind
        self.outputDirectory = outputDirectory
        self.segmentDuration = segmentDuration
        self.events = events
    }

    /// Takes a sample without writing it. It becomes writable only once a
    /// `release` covers the moment it arrived.
    func hold(_ sampleBuffer: CMSampleBuffer, arrivedAt: UInt64) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        pending.append((arrivedAt, sampleBuffer))
        if pending.count > Self.maximumPending {
            pending.removeFirst(pending.count - Self.maximumPending)
        }
    }

    /// Writes the held samples that arrived inside a stretch known to have had
    /// no excluded app in front, and drops anything older — no check can vouch
    /// for that any more, so it must not be written.
    func release(from: UInt64, through: UInt64) {
        guard !pending.isEmpty else { return }
        var held: [(arrivedAt: UInt64, buffer: CMSampleBuffer)] = []
        for entry in pending {
            if entry.arrivedAt > through {
                held.append(entry)
            } else if entry.arrivedAt >= from {
                append(entry.buffer)
            }
        }
        pending = held
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = sampleBuffer.presentationTimeStamp
        if let startedAt, CMTimeGetSeconds(timestamp - startedAt) >= segmentDuration {
            finishSegment()
        }
        if writer == nil {
            do {
                try beginSegment(sampleBuffer: sampleBuffer, timestamp: timestamp)
            } catch {
                events.send(.warning(code: "audio_writer_start", message: error.localizedDescription))
                return
            }
        }
        if input?.isReadyForMoreMediaData == true, input?.append(sampleBuffer) == false {
            events.send(.warning(code: "audio_append", message: writer?.error?.localizedDescription ?? "append failed"))
        }
    }

    /// Held samples are dropped rather than flushed: capture is stopping, so
    /// no check will ever vouch for the moment they were recorded.
    func finish() {
        pending.removeAll()
        finishSegment(waitForCompletion: true)
    }

    /// Closes the open segment so that whatever comes next starts a new file.
    /// Called when an excluded app takes the foreground: everything still held
    /// is dropped, and the audio from here on must not extend a file already
    /// on disk.
    func suspend() {
        pending.removeAll()
        finishSegment()
    }

    private func beginSegment(sampleBuffer: CMSampleBuffer, timestamp: CMTime) throws {
        let url = outputDirectory
            .appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let format = sampleBuffer.formatDescription
        let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: max(1, min(Int(channels ?? 1), 2)),
            AVEncoderBitRateKey: 96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "AfterRayCaptureShim", code: 1, userInfo: [NSLocalizedDescriptionKey: "audio input is unsupported"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AfterRayCaptureShim", code: 2)
        }
        writer.startSession(atSourceTime: timestamp)
        self.writer = writer
        self.input = input
        startedAt = timestamp
        startedAtMs = Self.nowMs()
        outputURL = url
    }

    private func finishSegment(waitForCompletion: Bool = false) {
        guard let writer, let input, let outputURL, let startedAtMs else { return }
        self.writer = nil
        self.input = nil
        self.startedAt = nil
        self.startedAtMs = nil
        self.outputURL = nil
        input.markAsFinished()
        let completion = DispatchSemaphore(value: 0)
        let sendableWriter = SendableAssetWriter(value: writer)
        writer.finishWriting { [events, kind, sendableWriter] in
            let completedWriter = sendableWriter.value
            if completedWriter.status == .completed {
                do {
                    try hardenPrivateFile(outputURL)
                } catch {
                    events.send(.warning(
                        code: "audio_file_permissions",
                        message: error.localizedDescription
                    ))
                    completion.signal()
                    return
                }
                events.send(.artifact(
                    kind: kind,
                    url: outputURL,
                    startedAtMs: startedAtMs,
                    endedAtMs: Self.nowMs()
                ))
            } else {
                events.send(.warning(
                    code: "audio_writer_finish",
                    message: completedWriter.error?.localizedDescription ?? "audio writer failed"
                ))
            }
            completion.signal()
        }
        if waitForCompletion, completion.wait(timeout: .now() + 10) == .timedOut {
            events.send(.warning(code: "audio_writer_timeout", message: "audio segment did not finish within ten seconds"))
        }
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let events: EventWriter
    private let systemAudio: AudioSegmentWriter?
    private let microphone: AudioSegmentWriter?
    let audioGate = ExcludedAudioGate()

    init(options: Options, audioPlan: AudioCapturePlan, events: EventWriter) {
        self.events = events
        if audioPlan.capturesSystemAudio {
            systemAudio = AudioSegmentWriter(
                kind: .systemAudio,
                outputDirectory: options.outputDirectory,
                segmentDuration: options.audioSegmentSeconds,
                events: events
            )
        } else {
            systemAudio = nil
        }
        if audioPlan.capturesMicrophone {
            microphone = AudioSegmentWriter(
                kind: .microphone,
                outputDirectory: options.outputDirectory,
                segmentDuration: options.audioSegmentSeconds,
                events: events
            )
        } else {
            microphone = nil
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            break
        case .audio:
            ingest(sampleBuffer, into: systemAudio)
        case .microphone:
            ingest(sampleBuffer, into: microphone)
        @unknown default:
            break
        }
    }

    /// Nothing is written until a foreground check vouches for the moment the
    /// sample was recorded. Writing first and cutting on the next check would
    /// leave every sample since the previous check inside a file the daemon
    /// then imports into the vault and hands to ASR — which is exactly the
    /// audio an exclusion is supposed to prevent.
    private func ingest(_ sampleBuffer: CMSampleBuffer, into writer: AudioSegmentWriter?) {
        let arrivedAt = DispatchTime.now().uptimeNanoseconds
        switch audioGate.state {
        case .excluded:
            suspendAudio()
        case .unknown:
            writer?.hold(sampleBuffer, arrivedAt: arrivedAt)
        case let .clear(from, through):
            writer?.hold(sampleBuffer, arrivedAt: arrivedAt)
            writer?.release(from: from, through: through)
        }
    }

    /// Both tracks are cut, not just the one whose buffer arrived: the
    /// microphone can be silent while system audio plays, and a segment left
    /// open across the excluded stretch would join the audio on either side of
    /// it into one file.
    private func suspendAudio() {
        systemAudio?.suspend()
        microphone?.suspend()
    }

    func stream(_: SCStream, didStopWithError error: any Error) {
        events.send(.failed(code: "stream_stopped", message: error.localizedDescription))
    }

    func finishAudio() {
        systemAudio?.finish()
        microphone?.finish()
    }
}

@MainActor
private func captureScreen(
    requestId: String,
    options: Options,
    events: EventWriter
) async throws {
    // Screenshots are pull-based: Rust decides when a Moment is needed. The
    // native boundary does not introduce another hidden frame scheduler.
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let accessibility = try await captureAccessibilityTree(
        capturedAtMs: now,
        outputDirectory: options.outputDirectory,
        events: events
    )
    // No accessibility snapshot means no exclusion check: the daemon decides
    // whether a frame may be kept from the bundle id and URL in that snapshot
    // alone, so a screenshot sent without one can never be evaluated and would
    // stay in the vault whatever the user excluded. Skipping the tick loses a
    // frame; sending it loses the guarantee.
    guard let accessibility else { return }
    if case .privateBrowsing = accessibility { return }
    if case .foregroundChanged = accessibility {
        return
    }
    guard case let .artifact(accessibilityURL, context) = accessibility else { return }
    guard foregroundCaptureContextIsCurrent(context) else {
        try? FileManager.default.removeItem(at: accessibilityURL)
        return
    }
    let screenURL = options.outputDirectory
        .appendingPathComponent("screen-\(UUID().uuidString)")
        .appendingPathExtension("jpg")
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = captureDisplay(for: context, displays: content.displays) else {
            throw ShimError.noDisplay
        }
        guard foregroundCaptureContextIsCurrent(context) else {
            try? FileManager.default.removeItem(at: accessibilityURL)
            return
        }
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == afterRayAppBundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = screenshotConfiguration(for: display)
        log("capture_screen focused display id=\(display.displayID) \(display.width)x\(display.height)")
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        if !foregroundCaptureContextIsCurrent(context) {
            try? FileManager.default.removeItem(at: accessibilityURL)
            return
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: options.jpegQuality]
        ) else { throw ShimError.imageEncoding }
        try data.write(to: screenURL, options: Data.WritingOptions.atomic)
        try hardenPrivateFile(screenURL)
        events.send(.artifact(
            kind: .screen,
            url: screenURL,
            startedAtMs: now,
            endedAtMs: now,
            requestId: requestId
        ))
        events.send(.artifact(
            kind: .accessibility,
            url: accessibilityURL,
            startedAtMs: now,
            endedAtMs: now,
            requestId: requestId
        ))
    } catch {
        try? FileManager.default.removeItem(at: screenURL)
        try? FileManager.default.removeItem(at: accessibilityURL)
        throw error
    }
}

// MARK: - Input events (listen-only)
//
// CAP-005 discipline is enforced here, at the source (see
// docs/input-events-and-t1-acts-plan.md): plain keystrokes exist only as
// burst counts — key codes are read solely to classify command keys and never
// leave the tap callback; pointer coordinates live exactly as long as the
// element resolution they feed. Return/Tab/Esc count as command keys
// (2026-08-17 decision): they carry no character content and their
// "submit/execute" semantics is the strongest read-vs-write signal T1 has.

private struct InputTargetFrame: Encodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct InputAncestorRef: Encodable {
    let role: String?
    let label: String?
}

/// The resolved identity of the element an input landed on. `label` is
/// title/description only — never `AXValue`, which is the element's content.
private struct InputTargetRef: Encodable {
    let role: String?
    let label: String?
    let frame: InputTargetFrame?
    let ancestors: [InputAncestorRef]
}

private struct InputEventRecord: Encodable {
    var atMs: Int64
    var kind: String
    var endMs: Int64?
    var count: Int?
    var endedWith: String?
    var command: String?
    var bundleIdentifier: String?
    var target: InputTargetRef?

    enum CodingKeys: String, CodingKey {
        case kind, count, command, target
        case atMs = "at_ms"
        case endMs = "end_ms"
        case endedWith = "ended_with"
        case bundleIdentifier = "bundle_identifier"
    }

    init(atMs: Int64, kind: String) {
        self.atMs = atMs
        self.kind = kind
    }
}

/// Listen-only observation of user input, coalesced at the source.
///
/// The tap callback must return fast — a slow callback gets the tap disabled
/// by the system (`tapDisabledByTimeout`) — so it only classifies and
/// enqueues primitives; all AX resolution happens on the worker queue, where
/// the process-global 100ms messaging timeout bounds each query. Element
/// resolution is a single-element path (~a dozen attribute reads), never a
/// tree walk: capture cadence is unchanged by interaction intensity.
private final class InputEventMonitor: @unchecked Sendable {
    /// Batches are flushed at this cadence once records exist.
    private static let flushIntervalMs: Int64 = 2_000
    /// A typing burst closes after this much silence.
    private static let burstGapMs: Int64 = 2_000
    /// Scroll ticks within this gap coalesce into one burst.
    private static let scrollGapMs: Int64 = 1_000
    /// Producer-side cap (§7.5): records beyond this per flush window are
    /// dropped and counted, never queued.
    private static let recordsPerFlushCap = 40

    private enum KeyClass {
        case plain
        case autorepeat
        case command(String)
    }

    private let events: EventWriter
    private let excludedVerdict: (String?) -> Bool?
    private let outputDirectory: URL
    private let worker = DispatchQueue(label: "dev.afterray.capture.input", qos: .utility)
    private let tapLock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    // Worker-queue state — touched only on `worker`.
    private var records: [InputEventRecord] = []
    private var dropped = 0
    private var lastFlushMs: Int64 = 0
    private var burst: (startMs: Int64, endMs: Int64, count: Int, bundle: String?, target: InputTargetRef?)?
    private var scroll: (startMs: Int64, endMs: Int64, count: Int, bundle: String?, target: InputTargetRef?)?
    private var lastRawMs: Int64 = 0
    /// Where the user last put the caret with the mouse, and when. Feeds
    /// `TypingTarget`, which owns the rule and the reasons for it.
    private var lastClick: (atMs: Int64, target: InputTargetRef)?
    private var timer: DispatchSourceTimer?
    private var livenessTick = 0
    /// R3 pacing (see `EdgeSnapshotPacing`).
    private var edgePacing = EdgeSnapshotPacing()
    /// Frontmost bundle as of the last tick; a change is an R3 candidate the
    /// tap itself cannot observe (⌘Tab is a key, not a scope the tap resolves).
    private var lastFrontmostBundle: String?
    /// The window the most recent trigger click landed in, with the pid it
    /// belonged to. The pid is what makes it safe to reuse: an app switch
    /// invalidates the window without the shim having to observe the switch.
    private var pendingEdgeWindow: (window: AXUIElement, pid: pid_t)?

    init(
        events: EventWriter,
        excludedVerdict: @escaping (String?) -> Bool?,
        outputDirectory: URL
    ) {
        self.events = events
        self.excludedVerdict = excludedVerdict
        self.outputDirectory = outputDirectory
    }

    func start() {
        let now = Self.nowMs()
        worker.async {
            self.lastRawMs = now
            self.lastFlushMs = now
        }
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "dev.afterray.capture.input-tap"
        thread.start()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        tapLock.lock()
        let tap = self.tap
        let runLoop = self.runLoop
        tapLock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        timer?.cancel()
        worker.sync {
            self.closeBurst(endedWith: nil)
            self.closeScroll()
            self.flush(nowMs: Self.nowMs())
        }
    }

    private func runTapLoop() {
        let mask = Self.maskBit(.keyDown)
            | Self.maskBit(.leftMouseDown)
            | Self.maskBit(.rightMouseDown)
            | Self.maskBit(.otherMouseDown)
            | Self.maskBit(.scrollWheel)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<InputEventMonitor>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Accessibility permission covers listen-only taps (§7.3);
            // reaching here means it is missing. Capture continues without
            // input events — fail open, but say so, because downstream must
            // not read the absence of events as "the user did nothing".
            events.send(.warning(
                code: "input_tap_unavailable",
                message: "listen-only event tap could not be created"
            ))
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapLock.lock()
        self.tap = tap
        self.runLoop = runLoop
        tapLock.unlock()
        log("input tap started")
        CFRunLoopRun()
    }

    /// Runs on the tap thread. Classifies and enqueues; nothing else.
    private func handle(type: CGEventType, event: CGEvent) {
        let now = Self.nowMs()
        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let classified: KeyClass =
                autorepeat ? .autorepeat : Self.classify(keyCode: keyCode, flags: event.flags)
            // The key code goes no further than the classification above.
            worker.async { self.onKey(atMs: now, classified: classified) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let location = event.location
            worker.async { self.onClick(atMs: now, x: location.x, y: location.y) }
        case .scrollWheel:
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            let location = event.location
            worker.async { self.onScroll(atMs: now, x: location.x, y: location.y, momentum: momentum) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapLock.lock()
            let tap = self.tap
            tapLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("input tap re-enabled after disable event")
        default:
            break
        }
    }

    private func onKey(atMs: Int64, classified: KeyClass) {
        lastRawMs = atMs
        edgePacing.observeInput(atMs: atMs)
        switch classified {
        case .autorepeat:
            if burst != nil { burst?.endMs = atMs }
        case .plain:
            if burst != nil, atMs - (burst?.endMs ?? 0) <= Self.burstGapMs {
                burst?.endMs = atMs
                burst?.count += 1
            } else {
                closeBurst(endedWith: nil)
                burst = (atMs, atMs, 1, frontmostBundle(), resolveTypingTarget(atMs: atMs))
            }
        case .command(let name):
            closeBurst(endedWith: name)
            var record = InputEventRecord(atMs: atMs, kind: "command")
            record.command = name
            record.bundleIdentifier = frontmostBundle()
            record.target = resolveTypingTarget(atMs: atMs)
            append(record)
        }
    }

    private func onClick(atMs: Int64, x: Double, y: Double) {
        lastRawMs = atMs
        // A click into another pane usually precedes typing there; close the
        // burst so its recorded target stays honest.
        closeBurst(endedWith: nil)
        var record = InputEventRecord(atMs: atMs, kind: "click")
        record.bundleIdentifier = frontmostBundle()
        let element = elementAt(x: x, y: y)
        record.target = element.map(targetRef(for:))
        if let target = record.target {
            lastClick = (atMs, target)
        }
        // R3: a click is a candidate scope change, and the window it landed in
        // is the walk root. The coordinates are already gone by here.
        if isRecordable(record.bundleIdentifier) {
            pendingEdgeWindow = element
                .flatMap(enclosingWindow(of:))
                .flatMap { window in elementPid(window).map { (window, $0) } }
            edgePacing.arm(atMs: atMs)
        }
        append(record)
    }

    private func onScroll(atMs: Int64, x: Double, y: Double, momentum: Bool) {
        lastRawMs = atMs
        edgePacing.observeInput(atMs: atMs)
        if scroll != nil, atMs - (scroll?.endMs ?? 0) <= Self.scrollGapMs {
            scroll?.endMs = atMs
            scroll?.count += 1
            return
        }
        // A momentum tail after the burst already closed is not a new act.
        if momentum { return }
        closeScroll()
        scroll = (atMs, atMs, 1, frontmostBundle(), resolveTarget(x: x, y: y))
    }

    private func closeBurst(endedWith: String?) {
        guard let current = burst else { return }
        burst = nil
        var record = InputEventRecord(atMs: current.startMs, kind: "burst")
        record.endMs = current.endMs
        record.count = current.count
        record.endedWith = endedWith
        record.bundleIdentifier = current.bundle
        record.target = current.target
        append(record)
    }

    private func closeScroll() {
        guard let current = scroll else { return }
        scroll = nil
        var record = InputEventRecord(atMs: current.startMs, kind: "scroll")
        record.endMs = current.endMs
        record.count = current.count
        record.bundleIdentifier = current.bundle
        record.target = current.target
        append(record)
    }

    /// The shim never records its own host app, and fails closed for excluded
    /// apps exactly like the audio hold: before the daemon's list arrives,
    /// nothing can be judged, so nothing is recorded. Gates the event stream
    /// and R3 alike — an excluded app's tree is never even walked.
    private func isRecordable(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier != afterRayAppBundleIdentifier
            && excludedVerdict(bundleIdentifier) == false
    }

    private func append(_ record: InputEventRecord) {
        guard isRecordable(record.bundleIdentifier) else { return }
        guard records.count < Self.recordsPerFlushCap else {
            dropped += 1
            return
        }
        records.append(record)
    }

    private func tick() {
        let now = Self.nowMs()
        if let current = burst, now - current.endMs > Self.burstGapMs {
            closeBurst(endedWith: nil)
        }
        if let current = scroll, now - current.endMs > Self.scrollGapMs {
            closeScroll()
        }
        if !records.isEmpty || dropped > 0, now - lastFlushMs >= Self.flushIntervalMs {
            flush(nowMs: now)
        }
        considerEdgeSnapshot(nowMs: now)
        livenessTick += 1
        if livenessTick >= 60 {
            livenessTick = 0
            checkLiveness(nowMs: now)
        }
    }

    private func flush(nowMs: Int64) {
        lastFlushMs = nowMs
        guard !records.isEmpty || dropped > 0 else { return }
        events.send(.inputEvents(records, dropped: dropped))
        records = []
        dropped = 0
    }

    /// Code-signature changes disable taps silently. If the system saw input
    /// recently but the tap saw nothing for a minute, the tap is dead —
    /// downstream must mark the gap rather than read it as "no activity".
    private func checkLiveness(nowMs: Int64) {
        let systemIdle = min(
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel)
        )
        if systemIdle < 30, nowMs - lastRawMs > 60_000 {
            events.send(.warning(
                code: "input_tap_stalled",
                message: "system saw input but the tap did not; re-enabling"
            ))
            tapLock.lock()
            let tap = self.tap
            tapLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    // MARK: R3 edge snapshots — worker queue only

    /// Decides whether this tick owes an edge snapshot, and takes it.
    ///
    /// The frontmost-app poll lives here rather than in a notification: the main
    /// thread blocks in `readLine` and never services a run loop, so
    /// `NSWorkspace` notifications would not arrive — the same reason the audio
    /// gate polls. One call a second on a queue that is already awake.
    private func considerEdgeSnapshot(nowMs: Int64) {
        let bundle = frontmostBundle()
        if bundle != lastFrontmostBundle {
            lastFrontmostBundle = bundle
            if isRecordable(bundle) {
                // A switch invalidates the click's window; the new app's
                // focused window is the honest root.
                pendingEdgeWindow = nil
                edgePacing.arm(atMs: nowMs)
            }
        }
        // The walk's own guards can still decline (browser, excluded app, no
        // resolvable window); `fire` spends the allowance only if one happened.
        edgePacing.fire(nowMs: nowMs) { captureEdgeSnapshot(nowMs: nowMs) }
    }

    /// Walks the window the trigger landed in and emits it as an
    /// `accessibility_edge` artifact.
    ///
    /// **Never a screenshot.** An event-driven frame would outlive the events
    /// that triggered it (events are deleted after 48h, frames are not) and so
    /// would keep exposing the instants a person interacted long after the
    /// record of that interaction was erased. Edge snapshots share the events'
    /// 48h lifetime for the same reason.
    ///
    /// Walk cost is bounded by exactly what bounds the heartbeat:
    /// `AccessibilityTreeEncoder`'s 500ms deadline, the menu-bar stub, and the
    /// process-global 100ms messaging timeout.
    @discardableResult
    private func captureEdgeSnapshot(nowMs: Int64) -> Bool {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            let bundle = application.bundleIdentifier,
            isRecordable(bundle)
        else { return false }
        // Private-browsing detection needs the async automation probe plus a
        // chrome-only pre-walk that the heartbeat runs before it touches a
        // browser tree; neither fits a 1s worker tick. v1 therefore takes no
        // edge snapshots of browsers at all — fail closed, heartbeat covers it.
        guard !BrowserPrivacyDetector(bundleIdentifier: bundle).isKnownBrowser else { return false }
        let pid = application.processIdentifier
        guard let root = edgeWalkRoot(pid: pid) else { return false }
        let encoder = AccessibilityTreeEncoder()
        let encodedRoot = encoder.encode(root)
        let snapshot = AccessibilitySnapshot(
            capturedAtMs: nowMs,
            processId: pid,
            bundleIdentifier: bundle,
            applicationName: application.localizedName,
            windowTitle: encoder.windowTitle,
            url: encoder.url,
            document: encoder.document,
            privateBrowsing: false,
            truncated: encoder.truncated,
            digest: encoder.digest(
                applicationName: application.localizedName,
                bundleIdentifier: bundle,
                windowTitle: encoder.windowTitle,
                privateBrowsing: false
            ),
            root: encodedRoot
        )
        let url = outputDirectory
            .appendingPathComponent("accessibility-edge-\(UUID().uuidString)")
            .appendingPathExtension("json")
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try hardenPrivateFile(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            log("edge snapshot could not be written: \(String(describing: error))")
            return false
        }
        events.send(
            .artifact(kind: .accessibilityEdge, url: url, startedAtMs: nowMs, endedAtMs: nowMs)
        )
        return true
    }

    /// The trigger click's own `AXWindow` when it still belongs to the app in
    /// front, else that app's focused window.
    ///
    /// v1 walks the whole window rather than the engaged subtree: the window is
    /// a superset of it, so nothing the join wants is missing, and the geometry
    /// that decides the subtree lives in the store's pure join, not here.
    private func edgeWalkRoot(pid: pid_t) -> AXUIElement? {
        if let pending = pendingEdgeWindow, pending.pid == pid {
            return pending.window
        }
        return frontWindowElement(AXUIElementCreateApplication(pid))
    }

    // MARK: resolution — worker queue only

    private func frontmostBundle() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func resolveTarget(x: Double, y: Double) -> InputTargetRef? {
        elementAt(x: x, y: y).map(targetRef(for:))
    }

    /// The element under a pointer position. The coordinates die with this
    /// stack frame — every caller keeps element identity, never a location.
    private func elementAt(x: Double, y: Double) -> AXUIElement? {
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(x), Float(y), &element
            ) == .success
        else { return nil }
        return element
    }

    /// The `AXWindow` an element belongs to, walking parents. Bounded: a
    /// pathological tree must not turn one click into an unbounded climb.
    private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var cursor: AXUIElement? = element
        var hops = 0
        while let current = cursor, hops < 12 {
            if isWindowRole(axString(current, kAXRoleAttribute)) { return current }
            cursor = axElement(current, kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    private func elementPid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Where a keystroke landed: system focus when the app named something
    /// typeable, otherwise the last click. The rule itself lives in
    /// `TypingTarget` so it can be tested without live Accessibility.
    private func resolveTypingTarget(atMs: Int64) -> InputTargetRef? {
        let focused = axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
            .map(targetRef(for:))
        let age = lastClick.map { atMs - $0.atMs }
        switch TypingTarget.choose(focusedRole: focused?.role, lastClickAgeMs: age) {
        case .focus:
            return focused
        case .lastClick:
            return lastClick?.target ?? focused
        }
    }

    private func targetRef(for element: AXUIElement) -> InputTargetRef {
        var ancestors: [InputAncestorRef] = []
        var cursor = axElement(element, kAXParentAttribute)
        var hops = 0
        while let parent = cursor, hops < 6 {
            let role = axString(parent, kAXRoleAttribute)
            if role == "AXApplication" { break }
            let label = nonempty(axString(parent, kAXTitleAttribute))
                ?? nonempty(axString(parent, kAXDescriptionAttribute))
            if role != nil || label != nil {
                ancestors.append(InputAncestorRef(role: role, label: label.map { clip($0, 80) }))
            }
            cursor = axElement(parent, kAXParentAttribute)
            hops += 1
        }
        let frame = accessibilityFrame(element).map {
            InputTargetFrame(
                x: Int($0.origin.x.rounded()),
                y: Int($0.origin.y.rounded()),
                width: Int($0.width.rounded()),
                height: Int($0.height.rounded())
            )
        }
        let label = nonempty(axString(element, kAXTitleAttribute))
            ?? nonempty(axString(element, kAXDescriptionAttribute))
        return InputTargetRef(
            role: axString(element, kAXRoleAttribute),
            label: label.map { clip($0, 120) },
            frame: frame,
            ancestors: ancestors
        )
    }

    private static func classify(keyCode: Int64, flags: CGEventFlags) -> KeyClass {
        if flags.contains(.maskCommand) {
            // Hardware key codes are ANSI positions; on other layouts a
            // letter command may misname, but still records as a command.
            let name: String
            switch keyCode {
            case 0: name = "cmd-a"
            case 1: name = "cmd-s"
            case 3: name = "cmd-f"
            case 6: name = "cmd-z"
            case 7: name = "cmd-x"
            case 8: name = "cmd-c"
            case 9: name = "cmd-v"
            case 36, 76: name = "cmd-return"
            default: name = "cmd"
            }
            return .command(name)
        }
        // Position keys, layout-independent.
        switch keyCode {
        case 36, 76: return .command("return")
        case 48: return .command("tab")
        case 53: return .command("esc")
        default: return .plain
        }
    }

    private static func maskBit(_ type: CGEventType) -> CGEventMask {
        CGEventMask(1) << CGEventMask(type.rawValue)
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

private struct InputCommand: Decodable {
    let command: String
    let requestId: String?
    let bundleIds: [String]?

    enum CodingKeys: String, CodingKey {
        case command
        case requestId = "request_id"
        case bundleIds = "bundle_ids"
    }
}

@main
private enum AfterRayCaptureShim {
    static func main() async {
        let events = EventWriter()
        do {
            let options = try Options.parse(CommandLine.arguments)
            let audioPlan = AudioCapturePlan(
                recordsAudio: options.recordAudio,
                hasMicrophoneInput: AVCaptureDevice.default(for: .audio) != nil
            )
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
            try hardenPrivateDirectory(options.outputDirectory)
            // Bound every AX attribute read process-wide. Each read is
            // synchronous IPC into the target app; the system default is 6s
            // per call, so one wedged app could stall a tick — and the paired
            // screenshot behind it — essentially unboundedly. 100ms per call
            // is what makes AccessibilityTreeEncoder's 500ms walk budget
            // real. Known cost: the very first snapshot of a freshly
            // launched Electron app can time out while it builds its AX
            // tree, degrading that one tick; the next heartbeat recovers.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
            log(
                "starting systemAudio=\(audioPlan.capturesSystemAudio) "
                    + "microphone=\(audioPlan.capturesMicrophone) output=\(options.outputDirectory.path)"
            )
            if options.recordAudio, !audioPlan.capturesMicrophone {
                log("no microphone input is available; continuing with system audio only")
            }
            log("requesting SCShareableContent")
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let streamDisplay = content.displays.first else { throw ShimError.noDisplay }
            log(
                "got audio stream display id=\(streamDisplay.displayID) "
                    + "\(streamDisplay.width)x\(streamDisplay.height) apps=\(content.applications.count)"
            )

            let configuration = SCStreamConfiguration()
            configuration.width = streamDisplay.width
            configuration.height = streamDisplay.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            configuration.queueDepth = 3
            configuration.showsCursor = true
            configuration.capturesAudio = audioPlan.capturesSystemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = audioPlan.capturesMicrophone

            let excludedApplications = content.applications.filter {
                $0.bundleIdentifier == afterRayAppBundleIdentifier
            }
            let streamFilter = SCContentFilter(
                display: streamDisplay,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let output = CaptureOutput(options: options, audioPlan: audioPlan, events: events)
            let stream = SCStream(filter: streamFilter, configuration: configuration, delegate: output)
            let callbackQueue = DispatchQueue(label: "dev.afterray.capture.samples", qos: .userInitiated)
            if audioPlan.capturesSystemAudio {
                // Its own queue: the sample handler must never wait on this,
                // and the main thread is blocked in `readLine` most of the time.
                output.audioGate.start(
                    queue: DispatchQueue(label: "dev.afterray.capture.foreground", qos: .utility)
                )
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: callbackQueue)
            }
            if audioPlan.capturesMicrophone {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: callbackQueue)
            }
            log("calling SCStream.startCapture")
            try await stream.startCapture()
            log("startCapture returned, sending ready")
            events.send(.ready(display: streamDisplay))

            // Listen-only input observation, coalesced at the source
            // (docs/input-events-and-t1-acts-plan.md phase 1). Shares the
            // audio gate's exclusion list; fails open into a warning event
            // when the tap cannot be created.
            let inputMonitor = InputEventMonitor(
                events: events,
                excludedVerdict: { output.audioGate.excludedVerdict(for: $0) },
                outputDirectory: options.outputDirectory
            )
            inputMonitor.start()

            let decoder = JSONDecoder()
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8) else { continue }
                do {
                    let command = try decoder.decode(InputCommand.self, from: data)
                    switch command.command {
                    case "capture_screen":
                        guard let requestId = command.requestId, !requestId.isEmpty else {
                            events.send(.warning(code: "invalid_command", message: "capture_screen requires request_id"))
                            continue
                        }
                        try await captureScreen(
                            requestId: requestId,
                            options: options,
                            events: events
                        )
                    case "set_excluded_bundles":
                        output.audioGate.setExcludedBundles(command.bundleIds ?? [])
                    case "stop":
                        inputMonitor.stop()
                        try await stream.stopCapture()
                        callbackQueue.sync { output.finishAudio() }
                        events.send(.stopped)
                        return
                    default:
                        events.send(.warning(code: "invalid_command", message: "unknown command \(command.command)"))
                    }
                } catch {
                    events.send(.warning(code: "command_failed", message: error.localizedDescription))
                }
            }
            // Reached by the `stop` command and by stdin closing under us — a
            // daemon crash takes the pipe with it. `stop()` is idempotent, and
            // it is what flushes the events buffered since the last tick, so
            // running it on both paths is what keeps a crash from silently
            // eating the last couple of seconds of acts.
            inputMonitor.stop()
            try await stream.stopCapture()
            callbackQueue.sync { output.finishAudio() }
            events.send(.stopped)
        } catch {
            log("startup failed: \(String(describing: error))")
            events.send(.failed(code: "startup", message: String(describing: error)))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private func log(_ message: String) {
    let line = "capture-shim: \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func captureDisplay(
    for context: ForegroundCaptureContext,
    displays: [SCDisplay]
) -> SCDisplay? {
    let fallbackDisplayID = displays.first {
        $0.displayID == CGMainDisplayID()
    }?.displayID ?? displays.first?.displayID
    let displayID = CaptureDisplaySelection.displayID(
        for: context.windowFrame,
        displays: displays.map {
            CaptureDisplayGeometry(id: $0.displayID, frame: CGDisplayBounds($0.displayID))
        },
        fallbackDisplayID: fallbackDisplayID
    )
    return displays.first { $0.displayID == displayID }
}

private func screenshotConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    let pixelSize = nativePixelSize(for: display)
    configuration.width = pixelSize.width
    configuration.height = pixelSize.height
    configuration.captureResolution = .best
    configuration.showsCursor = true
    return configuration
}

private func nativePixelSize(for display: SCDisplay) -> (width: Int, height: Int) {
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
        return (
            width: max(mode.pixelWidth, display.width),
            height: max(mode.pixelHeight, display.height)
        )
    }

    let screen = NSScreen.screens.first { screen in
        let screenNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        return screenNumber?.uint32Value == display.displayID
    }
    let scale = max(screen?.backingScaleFactor ?? 1, 1)
    return (
        width: Int((CGFloat(display.width) * scale).rounded()),
        height: Int((CGFloat(display.height) * scale).rounded())
    )
}
