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

    enum CodingKeys: String, CodingKey {
        case event, kind, path, code, message
        case contentType = "content_type"
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case byteCount = "byte_count"
        case requestId = "request_id"
        case displayId = "display_id"
        case width, height
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
        case .accessibility: contentType = "application/vnd.afterray.ax+json"
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
        guard nodeCount <= maximumNodes, visited.insert(identity).inserted else {
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
        guard
            let positionValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return AccessibilityFrame(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
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
    let browserWindowId: CGWindowID?
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
    let browserWindow = preflightDetector.isKnownBrowser ? frontWindowElement(appElement) : nil
    let context: ForegroundCaptureContext
    let captureRoot: AXUIElement
    if preflightDetector.isKnownBrowser {
        guard
            let browserWindow,
            let browserWindowId = cgFrontWindowId(for: application.processIdentifier)
        else { return .foregroundChanged }
        context = ForegroundCaptureContext(
            processId: application.processIdentifier,
            browserWindowId: browserWindowId
        )
        captureRoot = browserWindow
    } else {
        context = ForegroundCaptureContext(
            processId: application.processIdentifier,
            browserWindowId: nil
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
    guard capturedForegroundApplication()?.processIdentifier == context.processId else { return false }
    guard let browserWindowId = context.browserWindowId else { return true }
    return cgFrontWindowId(for: context.processId) == browserWindowId
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

    init(kind: ArtifactKind, outputDirectory: URL, segmentDuration: Double, events: EventWriter) {
        self.kind = kind
        self.outputDirectory = outputDirectory
        self.segmentDuration = segmentDuration
        self.events = events
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
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

    func finish() {
        finishSegment(waitForCompletion: true)
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

    init(options: Options, events: EventWriter) {
        self.events = events
        if options.recordAudio {
            systemAudio = AudioSegmentWriter(
                kind: .systemAudio,
                outputDirectory: options.outputDirectory,
                segmentDuration: options.audioSegmentSeconds,
                events: events
            )
            microphone = AudioSegmentWriter(
                kind: .microphone,
                outputDirectory: options.outputDirectory,
                segmentDuration: options.audioSegmentSeconds,
                events: events
            )
        } else {
            systemAudio = nil
            microphone = nil
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            break
        case .audio:
            systemAudio?.append(sampleBuffer)
        case .microphone:
            microphone?.append(sampleBuffer)
        @unknown default:
            break
        }
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
    filter: SCContentFilter,
    configuration: SCStreamConfiguration,
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
    if case .privateBrowsing? = accessibility { return }
    if case .foregroundChanged? = accessibility {
        return
    }
    if case let .artifact(accessibilityURL, context)? = accessibility,
       !foregroundCaptureContextIsCurrent(context)
    {
        try? FileManager.default.removeItem(at: accessibilityURL)
        return
    }
    let screenURL = options.outputDirectory
        .appendingPathComponent("screen-\(UUID().uuidString)")
        .appendingPathExtension("jpg")
    do {
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        if case let .artifact(accessibilityURL, context)? = accessibility,
           !foregroundCaptureContextIsCurrent(context)
        {
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
        if case let .artifact(accessibilityURL, _)? = accessibility {
            events.send(.artifact(
                kind: .accessibility,
                url: accessibilityURL,
                startedAtMs: now,
                endedAtMs: now,
                requestId: requestId
            ))
        }
    } catch {
        try? FileManager.default.removeItem(at: screenURL)
        if case let .artifact(accessibilityURL, _)? = accessibility {
            try? FileManager.default.removeItem(at: accessibilityURL)
        }
        throw error
    }
}

private struct InputCommand: Decodable {
    let command: String
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case command
        case requestId = "request_id"
    }
}

@main
private enum AfterRayCaptureShim {
    static func main() async {
        let events = EventWriter()
        do {
            let options = try Options.parse(CommandLine.arguments)
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
            try hardenPrivateDirectory(options.outputDirectory)
            log("starting recordAudio=\(options.recordAudio) output=\(options.outputDirectory.path)")
            log("requesting SCShareableContent")
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { throw ShimError.noDisplay }
            log("got display id=\(display.displayID) \(display.width)x\(display.height) apps=\(content.applications.count)")

            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            configuration.queueDepth = 3
            configuration.showsCursor = true
            configuration.capturesAudio = options.recordAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = options.recordAudio

            let screenshotConfiguration = SCStreamConfiguration()
            let screenshotPixelSize = nativePixelSize(for: display)
            screenshotConfiguration.width = screenshotPixelSize.width
            screenshotConfiguration.height = screenshotPixelSize.height
            screenshotConfiguration.captureResolution = .best
            screenshotConfiguration.showsCursor = true

            let excludedApplications = content.applications.filter {
                $0.bundleIdentifier == afterRayAppBundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let output = CaptureOutput(options: options, events: events)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            let callbackQueue = DispatchQueue(label: "dev.afterray.capture.samples", qos: .userInitiated)
            if options.recordAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: callbackQueue)
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: callbackQueue)
            }
            log("calling SCStream.startCapture")
            try await stream.startCapture()
            log("startCapture returned, sending ready")
            events.send(.ready(display: display))

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
                            filter: filter,
                            configuration: screenshotConfiguration,
                            options: options,
                            events: events
                        )
                    case "stop":
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
