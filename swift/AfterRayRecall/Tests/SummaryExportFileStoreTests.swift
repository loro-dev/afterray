import Foundation
import XCTest
@testable import AfterRayRecall

final class SummaryExportFileStoreTests: XCTestCase {
    func testWritesUniquePrettyJSONWithPrivatePermissionsAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "afterray-export-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SummaryExportFileStore(temporaryRoot: root)
        try await store.prepareForLaunch()

        let first = try await store.write(fixture)
        let second = try await store.write(fixture)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        let decoded = try JSONDecoder().decode(SlotSummaryExport.self, from: Data(contentsOf: first))
        XCTAssertEqual(decoded, fixture)
        let text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.contains("\n  \"facts\""), "export should be pretty-printed")

        let directoryMode = try permissionMode(at: await store.directory)
        let fileMode = try permissionMode(at: first)
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)

        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-SummaryExportFileStore.maximumAge - 1)],
            ofItemAtPath: first.path
        )
        try await store.cleanupExpired(now: .now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        try await store.cleanupAll()
        let directoryAfterCleanup = await store.directory
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryAfterCleanup.path))
    }

    func testWritesPrivateMarkdownWithAStableTrailingNewline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "afterray-markdown-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SummaryExportFileStore(temporaryRoot: root)

        let url = try await store.write(markdown: "20:00 Shipped the fix")

        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "20:00 Shipped the fix\n")
        XCTAssertEqual(try permissionMode(at: url), 0o600)
    }

    private var fixture: SlotSummaryExport {
        SlotSummaryExport(
            slotStartMs: 100,
            slotEndMs: 200,
            state: "done",
            schemaVersion: 2,
            summary: SlotSummaryPayload(
                title: "Implemented export",
                description: "A private JSON file was opened.",
                threads: [SummaryThread(name: "Export", prose: "Validated permissions.")]
            ),
            facts: DaySlotFacts(apps: [DayAppFact(name: "AfterRay", ms: 60_000)], momentCount: 4),
            generation: 1,
            producer: "test",
            producedAtMs: 300,
            latencyMs: 20
        )
    }

    private func permissionMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int) & 0o777
    }
}
