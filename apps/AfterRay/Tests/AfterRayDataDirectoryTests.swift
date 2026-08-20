import Foundation
import XCTest
@testable import AfterRayApp

@MainActor
final class AfterRayDataDirectoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afterray-data-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDestinationLivesInAnAfterRayChild() {
        XCTAssertEqual(
            AfterRayDataDirectory.destination(in: directory).path,
            directory.appendingPathComponent("AfterRay", isDirectory: true).path
        )
    }

    func testNewDestinationUsesItsSelectedVolume() throws {
        let destination = AfterRayDataDirectory.destination(in: directory)
        let location = try AfterRayDataDirectory.location(for: destination)

        XCTAssertEqual(location.url, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.volumeRoot.path))
    }

    func testMoveContentsPreservesSocketAndMovesVaultAndModels() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: source.appendingPathComponent("afterray.sqlite3"))
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Models", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("socket".utf8).write(to: source.appendingPathComponent("afterray.sock"))

        let moves = try AfterRayDataDirectory.moveContents(
            from: source,
            to: destination,
            excluding: ["afterray.sock"]
        )

        XCTAssertEqual(moves.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("afterray.sqlite3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("artifacts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Models").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("afterray.sock").path))
    }

    func testMoveContentsRollsBackEarlierEntriesWhenDestinationConflicts() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("artifact".utf8).write(to: source.appendingPathComponent("artifacts"))
        try Data("vault".utf8).write(to: source.appendingPathComponent("afterray.sqlite3"))
        try Data("existing".utf8).write(to: destination.appendingPathComponent("afterray.sqlite3"))

        XCTAssertThrowsError(
            try AfterRayDataDirectory.moveContents(from: source, to: destination)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("artifacts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("afterray.sqlite3").path))
    }

    func testMigrationMovesSeparateDevelopmentModelsAndRuntime() throws {
        let sourceData = directory.appendingPathComponent("v0-data", isDirectory: true)
        let sourceModels = directory.appendingPathComponent("models", isDirectory: true)
        let sourceRuntime = directory.appendingPathComponent("mlx-runtime", isDirectory: true)
        let destination = directory.appendingPathComponent("external/AfterRay", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceModels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRuntime, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: sourceData.appendingPathComponent("afterray.sqlite3"))
        try Data("model".utf8).write(to: sourceModels.appendingPathComponent("weight.bin"))
        try Data("runtime".utf8).write(to: sourceRuntime.appendingPathComponent("cache.bin"))

        let moves = try AfterRayDataDirectory.migrate(
            sourceData: sourceData,
            sourceModels: sourceModels,
            sourceRuntime: sourceRuntime,
            destination: destination,
            socketName: "afterray.sock"
        )

        XCTAssertEqual(moves.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("afterray.sqlite3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Models/weight.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("mlx-runtime/cache.bin").path))
    }

    func testRollbackFailureIsReportedForManualRecovery() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("afterray.sqlite3")
        let destinationFile = destination.appendingPathComponent("afterray.sqlite3")
        try Data("old source".utf8).write(to: sourceFile)
        try Data("moved vault".utf8).write(to: destinationFile)

        XCTAssertThrowsError(
            try AfterRayDataDirectory.rollback([.init(source: sourceFile, destination: destinationFile)])
        ) { error in
            XCTAssertTrue(AfterRayDataDirectory.needsManualRecovery(error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFile.path))
    }

    func testRollbackRequiresSourceToExistWhenDestinationHasDisappeared() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("external", isDirectory: true)
        let move = AfterRayDataDirectory.Move(
            source: source.appendingPathComponent("afterray.sqlite3"),
            destination: destination.appendingPathComponent("afterray.sqlite3")
        )
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AfterRayDataDirectory.rollback([move])) { error in
            XCTAssertTrue(AfterRayDataDirectory.needsManualRecovery(error))
        }
    }

    func testRestartRecoversAnInterruptedMoveFromItsPersistentManifest() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("external/AfterRay", isDirectory: true)
        let manifestURL = directory
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("memory-location-recovery.json")
        let sourceFile = source.appendingPathComponent("afterray.sqlite3")
        let destinationFile = destination.appendingPathComponent("afterray.sqlite3")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: sourceFile)

        try AfterRayDataDirectory.beginMigration(
            sourceRoot: source,
            destinationRoot: destination,
            sourceLocation: try AfterRayDataDirectory.location(for: source),
            destinationLocation: try AfterRayDataDirectory.location(for: destination),
            manifestURL: manifestURL
        )
        let journal = try AfterRayDataDirectory.RecoveryJournal(manifestURL: manifestURL)
        try journal.markMoving()
        let move = AfterRayDataDirectory.Move(source: sourceFile, destination: destinationFile)
        try journal.recordIntent(move)
        try FileManager.default.moveItem(at: sourceFile, to: destinationFile)
        // This is the deterministic crash point: the item moved, but the
        // process died before it could record completion or run `catch`.

        XCTAssertEqual(
            try AfterRayDataDirectory.prepareInterruptedMigration(
                manifestURL: manifestURL,
                currentDataLocation: try AfterRayDataDirectory.location(for: source)
            ),
            .restoreSourceLocation(try AfterRayDataDirectory.location(for: source))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFile.path))
        // The filesystem phase must retain its journal until the main-actor
        // preference phase has durably selected the restored source.
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        try AfterRayDataDirectory.completeSourceRecovery(
            manifestURL: manifestURL,
            sourceLocation: try AfterRayDataDirectory.location(for: source)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testMovedManifestRejectsMixedLocationAndRestoresSource() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("external/AfterRay", isDirectory: true)
        let manifestURL = directory
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("memory-location-recovery.json")
        let sourceFile = source.appendingPathComponent("afterray.sqlite3")
        let destinationFile = destination.appendingPathComponent("afterray.sqlite3")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: sourceFile)

        let sourceLocation = try AfterRayDataDirectory.location(for: source)
        let destinationLocation = try AfterRayDataDirectory.location(for: destination)
        try AfterRayDataDirectory.beginMigration(
            sourceRoot: source,
            destinationRoot: destination,
            sourceLocation: sourceLocation,
            destinationLocation: destinationLocation,
            manifestURL: manifestURL
        )
        let journal = try AfterRayDataDirectory.RecoveryJournal(manifestURL: manifestURL)
        try journal.markMoving()
        let move = AfterRayDataDirectory.Move(source: sourceFile, destination: destinationFile)
        try journal.recordIntent(move)
        try FileManager.default.moveItem(at: sourceFile, to: destinationFile)
        try journal.recordCompletion(move)
        try journal.markMoved()

        let mixedLocation = AfterRayDataDirectory.Location(
            url: destinationLocation.url,
            volumeRoot: directory.appendingPathComponent("stale-volume", isDirectory: true),
            volumeUUID: "stale-volume-uuid"
        )
        let preferenceKeys = [
            AfterRayPreferences.memoryDataLocationKey,
            AfterRayPreferences.memoryDataDirectoryKey,
            AfterRayPreferences.memoryDataVolumeRootKey,
            AfterRayPreferences.memoryDataVolumeUUIDKey,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                originalPreferences[key] = value
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in preferenceKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            for (key, value) in originalPreferences {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        AfterRayPreferences.memoryDataLocation = mixedLocation

        XCTAssertEqual(
            try AfterRayDataDirectory.prepareInterruptedMigration(
                manifestURL: manifestURL,
                currentDataLocation: mixedLocation
            ),
            .restoreSourceLocation(sourceLocation)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        // This is the main-actor phase used by DaemonSupervisor. It must run
        // after the background rollback and before the journal can be removed.
        AfterRayPreferences.memoryDataLocation = sourceLocation
        XCTAssertEqual(AfterRayPreferences.canonicalMemoryDataLocation, sourceLocation)
        XCTAssertEqual(DaemonSupervisor.shared.dataDirectory, sourceLocation.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFile.path))
        try AfterRayDataDirectory.completeSourceRecovery(
            manifestURL: manifestURL,
            sourceLocation: sourceLocation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testRecoveryRetainsManifestWhenSourcePreferenceCannotPersist() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let destination = directory.appendingPathComponent("external/AfterRay", isDirectory: true)
        let manifestURL = directory
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("memory-location-recovery.json")
        let sourceFile = source.appendingPathComponent("afterray.sqlite3")
        let destinationFile = destination.appendingPathComponent("afterray.sqlite3")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("vault".utf8).write(to: sourceFile)

        let sourceLocation = try AfterRayDataDirectory.location(for: source)
        let destinationLocation = try AfterRayDataDirectory.location(for: destination)
        try AfterRayDataDirectory.beginMigration(
            sourceRoot: source,
            destinationRoot: destination,
            sourceLocation: sourceLocation,
            destinationLocation: destinationLocation,
            manifestURL: manifestURL
        )
        let journal = try AfterRayDataDirectory.RecoveryJournal(manifestURL: manifestURL)
        try journal.markMoving()
        let move = AfterRayDataDirectory.Move(source: sourceFile, destination: destinationFile)
        try journal.recordIntent(move)
        try FileManager.default.moveItem(at: sourceFile, to: destinationFile)
        try journal.recordCompletion(move)
        try journal.markMoved()

        XCTAssertEqual(
            try AfterRayDataDirectory.prepareInterruptedMigration(
                manifestURL: manifestURL,
                currentDataLocation: nil
            ),
            .restoreSourceLocation(sourceLocation)
        )
        // Simulate a main-actor preference write failure by deliberately not
        // running the completion phase. The rollback is complete, but the
        // durable journal remains to force the next launch to retry safely.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testValidationRejectsAChildOfTheCurrentVault() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try AfterRayDataDirectory.validateDestination(
                source.appendingPathComponent("AfterRay", isDirectory: true),
                currentDirectory: source
            )
        )
    }
}
