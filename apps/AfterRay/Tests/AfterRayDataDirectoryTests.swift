import Foundation
import XCTest
@testable import AfterRayApp

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
