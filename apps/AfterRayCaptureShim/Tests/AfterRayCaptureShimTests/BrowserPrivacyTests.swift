@testable import AfterRayCapturePolicy
import XCTest

final class BrowserPrivacyTests: XCTestCase {
    func testKnownBrowserChromeMarkerDetectsPrivateBrowsing() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.google.Chrome")

        detector.observe(
            role: "AXButton",
            title: "Incognito",
            nodeDescription: nil,
            identifier: nil,
            insideBrowserWindow: true,
            insideWebContent: false
        )

        XCTAssertEqual(
            detector.resolve(windowTitle: nil),
            .privateBrowsing(.accessibilityLabel)
        )
    }

    func testLocalizedBrowserChromeMarkerDetectsPrivateBrowsing() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.apple.Safari")

        detector.observe(
            role: "AXGroup",
            title: "无痕浏览",
            nodeDescription: nil,
            identifier: nil,
            insideBrowserWindow: true,
            insideWebContent: false
        )

        XCTAssertEqual(
            detector.resolve(windowTitle: nil),
            .privateBrowsing(.accessibilityLabel)
        )
    }

    func testWebContentCannotClaimPrivateBrowsing() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.google.Chrome")

        detector.observe(
            role: "AXHeading",
            title: "You're Incognito",
            nodeDescription: nil,
            identifier: nil,
            insideBrowserWindow: true,
            insideWebContent: true
        )

        XCTAssertEqual(detector.resolve(windowTitle: nil), .unknown)
    }

    func testNonBrowserCannotClaimPrivateBrowsing() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.example.notes")

        detector.observe(
            role: "AXButton",
            title: "Incognito",
            nodeDescription: nil,
            identifier: nil,
            insideBrowserWindow: true,
            insideWebContent: false
        )

        XCTAssertEqual(detector.resolve(windowTitle: nil), .regular(.notBrowser))
    }

    func testPrivateWindowMenuItemInsideBrowserWindowIsIgnored() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.apple.Safari")

        detector.observe(
            role: "AXMenuItem",
            title: "New Private Window",
            nodeDescription: nil,
            identifier: nil,
            insideBrowserWindow: true,
            insideWebContent: false
        )

        XCTAssertEqual(detector.resolve(windowTitle: nil), .unknown)
    }

    func testStableAccessibilityIdentifierWinsOverRegularAutomationResult() {
        var detector = BrowserPrivacyDetector(bundleIdentifier: "com.google.Chrome")
        detector.observe(
            role: "AXButton",
            title: nil,
            nodeDescription: nil,
            identifier: "kIncognitoAvatarButton",
            insideBrowserWindow: true,
            insideWebContent: false
        )

        XCTAssertEqual(
            detector.resolve(
                automationState: .regular(.browserAutomation),
                windowTitle: "Example"
            ),
            .privateBrowsing(.accessibilityIdentifier)
        )
    }

    func testFirefoxPrivateTitleRequiresAWindowTitleSuffix() {
        let detector = BrowserPrivacyDetector(bundleIdentifier: "org.mozilla.firefox")

        XCTAssertEqual(
            detector.resolve(windowTitle: "Mozilla Firefox — Private Browsing"),
            .privateBrowsing(.firefoxWindowTitle)
        )
        XCTAssertEqual(
            detector.resolve(windowTitle: "Private Browsing — Mozilla Firefox"),
            .unknown
        )
        XCTAssertEqual(
            detector.resolve(windowTitle: "示例 — 隐私浏览"),
            .privateBrowsing(.firefoxWindowTitle)
        )
    }

    func testChromiumAutomationQueryUsesAnAllowlistedBundleAndSentinels() throws {
        let query = try XCTUnwrap(
            BrowserPrivacyAutomationQuery.make(bundleIdentifier: "com.google.Chrome")
        )

        XCTAssertEqual(query.bundleIdentifier, "com.google.Chrome")
        XCTAssertTrue(query.script.contains("application id \"com.google.Chrome\""))
        XCTAssertFalse(query.script.lowercased().contains("url of"))
        XCTAssertEqual(
            query.parse(output: "afterray:private\n"),
            .privateBrowsing(.browserAutomation)
        )
        XCTAssertEqual(
            query.parse(output: "afterray:regular\n"),
            .regular(.browserAutomation)
        )
        XCTAssertEqual(query.parse(output: "permission denied"), .unknown)
    }

    func testArcAutomationQueryUsesOnlyTheIncognitoWindowFlag() throws {
        let query = try XCTUnwrap(
            BrowserPrivacyAutomationQuery.make(bundleIdentifier: "company.thebrowser.Browser")
        )

        XCTAssertTrue(query.script.contains("incognito of front window"))
        XCTAssertFalse(query.script.lowercased().contains("url of"))
    }

    func testRegularRequiresAnAuthoritativeAutomationResult() {
        let detector = BrowserPrivacyDetector(bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(detector.resolve(automationState: .unknown, windowTitle: nil), .unknown)
        XCTAssertEqual(
            detector.resolve(
                automationState: .regular(.browserAutomation),
                windowTitle: nil
            ),
            .regular(.browserAutomation)
        )
    }

    func testAutomationQueryRejectsUnsupportedOrUnsafeBundleIdentifiers() {
        XCTAssertNil(BrowserPrivacyAutomationQuery.make(bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(BrowserPrivacyAutomationQuery.make(bundleIdentifier: "org.mozilla.firefox"))
        XCTAssertNil(BrowserPrivacyAutomationQuery.make(bundleIdentifier: "com.example.browser"))
        XCTAssertNil(BrowserPrivacyAutomationQuery.make(
            bundleIdentifier: "com.google.Chrome\" to return URL of active tab --"
        ))
    }

    func testPrivateBrowsingRedactsWebURLsButKeepsFileLocations() {
        XCTAssertNil(BrowserPrivacyDetector.redactedURL(
            "https://private.example/account",
            privateBrowsing: true
        ))
        XCTAssertEqual(
            BrowserPrivacyDetector.redactedURL("file:///tmp/note.txt", privateBrowsing: true),
            "file:///tmp/note.txt"
        )
        XCTAssertEqual(
            BrowserPrivacyDetector.redactedURL(
                "https://public.example/",
                privateBrowsing: false
            ),
            "https://public.example/"
        )
    }

    func testPrivateBrowsingRedactsAddressFieldValueOutsideWebContent() {
        XCTAssertNil(BrowserPrivacyDetector.redactedBrowserChromeValue(
            "private.example/account",
            role: "AXTextField",
            insideWebContent: false,
            privateBrowsing: true
        ))
        XCTAssertEqual(
            BrowserPrivacyDetector.redactedBrowserChromeValue(
                "private.example/account",
                role: "AXStaticText",
                insideWebContent: true,
                privateBrowsing: true
            ),
            "private.example/account"
        )
    }
}
