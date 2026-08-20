import Foundation
import XCTest

@testable import AfterRayApp

@MainActor
final class AfterRayMemoryLocationPreferenceTests: XCTestCase {
    private let keys = [
        AfterRayPreferences.memoryDataLocationKey,
        AfterRayPreferences.memoryDataDirectoryKey,
        AfterRayPreferences.memoryDataVolumeRootKey,
        AfterRayPreferences.memoryDataVolumeUUIDKey,
    ]
    private var original: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        original = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                original[key] = value
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in original {
            UserDefaults.standard.set(value, forKey: key)
        }
        super.tearDown()
    }

    func testLegacyLocationMigratesToOneCanonicalValue() throws {
        let location = AfterRayDataDirectory.Location(
            url: URL(fileURLWithPath: "/Volumes/Archive/AfterRay", isDirectory: true),
            volumeRoot: URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true),
            volumeUUID: "archive-uuid"
        )
        UserDefaults.standard.set(location.url.path, forKey: AfterRayPreferences.memoryDataDirectoryKey)
        UserDefaults.standard.set(location.volumeRoot.path, forKey: AfterRayPreferences.memoryDataVolumeRootKey)
        UserDefaults.standard.set(location.volumeUUID, forKey: AfterRayPreferences.memoryDataVolumeUUIDKey)

        XCTAssertEqual(AfterRayPreferences.memoryDataLocation, location)
        XCTAssertEqual(AfterRayPreferences.canonicalMemoryDataLocation, location)
        XCTAssertNil(UserDefaults.standard.object(forKey: AfterRayPreferences.memoryDataDirectoryKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: AfterRayPreferences.memoryDataVolumeRootKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: AfterRayPreferences.memoryDataVolumeUUIDKey))
    }

    func testPartialLegacyLocationIsNotAccepted() {
        UserDefaults.standard.set(
            "/Volumes/NewArchive/AfterRay",
            forKey: AfterRayPreferences.memoryDataDirectoryKey
        )

        XCTAssertNil(AfterRayPreferences.memoryDataLocation)
        XCTAssertNil(AfterRayPreferences.canonicalMemoryDataLocation)
    }

    func testMalformedCanonicalValueCannotFallBackToLegacyFragments() {
        let legacy = AfterRayDataDirectory.Location(
            url: URL(fileURLWithPath: "/Volumes/OldArchive/AfterRay", isDirectory: true),
            volumeRoot: URL(fileURLWithPath: "/Volumes/OldArchive", isDirectory: true),
            volumeUUID: "old-uuid"
        )
        UserDefaults.standard.set(Data("not json".utf8), forKey: AfterRayPreferences.memoryDataLocationKey)
        UserDefaults.standard.set(legacy.url.path, forKey: AfterRayPreferences.memoryDataDirectoryKey)
        UserDefaults.standard.set(legacy.volumeRoot.path, forKey: AfterRayPreferences.memoryDataVolumeRootKey)
        UserDefaults.standard.set(legacy.volumeUUID, forKey: AfterRayPreferences.memoryDataVolumeUUIDKey)

        XCTAssertNil(AfterRayPreferences.memoryDataLocation)
        XCTAssertNil(AfterRayPreferences.canonicalMemoryDataLocation)
    }
}
