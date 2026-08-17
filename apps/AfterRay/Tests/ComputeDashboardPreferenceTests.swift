import XCTest

@testable import AfterRayApp

/// The dashboard is opt-in, and the thing that must not regress is the default.
/// It exposes worker processes, queue depths and gate thresholds — useful when
/// the fans are loud, implementation detail the rest of the time — and every
/// control it carries already has automatic behaviour behind it.
@MainActor
final class ComputeDashboardPreferenceTests: XCTestCase {
    private var original: Any?

    override func setUp() {
        super.setUp()
        original = UserDefaults.standard.object(
            forKey: AfterRayPreferences.computeDashboardKey
        )
        UserDefaults.standard.removeObject(forKey: AfterRayPreferences.computeDashboardKey)
    }

    override func tearDown() {
        if let original {
            UserDefaults.standard.set(original, forKey: AfterRayPreferences.computeDashboardKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AfterRayPreferences.computeDashboardKey)
        }
        super.tearDown()
    }

    func testTheDashboardIsOffUntilSomebodyAsksForIt() {
        XCTAssertFalse(
            AfterRayPreferences.computeDashboardEnabled,
            "an unset preference must read as off, not as 'no opinion, show it anyway'"
        )
    }

    func testTheSwitchPersistsAndAnnouncesItself() {
        // The menu bar item and the overlay button both follow this notification
        // rather than being rebuilt, so losing it silently strands both.
        let announced = expectation(
            forNotification: .afterRayPreferencesDidChange,
            object: nil,
            handler: nil
        )

        AfterRayPreferences.computeDashboardEnabled = true
        XCTAssertTrue(AfterRayPreferences.computeDashboardEnabled)
        wait(for: [announced], timeout: 1)

        AfterRayPreferences.computeDashboardEnabled = false
        XCTAssertFalse(AfterRayPreferences.computeDashboardEnabled)
    }
}
