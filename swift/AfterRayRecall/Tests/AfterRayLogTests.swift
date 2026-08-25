import XCTest
@testable import AfterRayRecall

final class AfterRayLogTests: XCTestCase {
    func testDiagnosticsReportIncludesLogPath() {
        AfterRayLog.install()
        AfterRayLog.info("settings-lab smoke")
        let report = AfterRayLog.diagnosticsReport()
        XCTAssertTrue(report.contains("AfterRay diagnostics"))
        XCTAssertTrue(report.contains(AfterRayLog.fileURL.path))
        XCTAssertTrue(report.contains("settings-lab smoke"))
    }

    func testStorageShareTextExplainsTinyAfterRayFootprint() {
        let snapshot = AfterRayStorageSnapshot(
            vaultBytes: 80_000_000,
            modelBytes: 20_000_000,
            runtimeBytes: 0,
            volumeTotal: 1_000_000_000_000,
            volumeFree: 200_000_000_000
        )
        XCTAssertEqual(snapshot.otherBytes, 799_900_000_000)
        XCTAssertTrue(snapshot.diskShareText.contains("less than 0.1%"))
        XCTAssertTrue(snapshot.diskShareText.contains("disk"))
    }

    func testStorageMeasureDoesNotDoubleCountNestedModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afterray-storage-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 1_000).write(to: artifacts.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 4_000).write(to: models.appendingPathComponent("m.bin"))

        let snapshot = AfterRayStorageSnapshot.measure(
            dataDirectory: root,
            modelDirectory: models,
            runtimeDirectory: root.appendingPathComponent("mlx-runtime", isDirectory: true)
        )
        XCTAssertEqual(snapshot.vaultBytes, 1_000)
        XCTAssertEqual(snapshot.modelBytes, 4_000)
        XCTAssertEqual(snapshot.afterrayBytes, 5_000)
    }

    func testStorageMeasureOffMainMatchesSynchronousMeasure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("afterray-storage-async-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 1_000).write(to: models.appendingPathComponent("m.bin"))

        let expected = AfterRayStorageSnapshot.measure(
            dataDirectory: root,
            modelDirectory: models,
            runtimeDirectory: root.appendingPathComponent("mlx-runtime", isDirectory: true)
        )
        let actual = await AfterRayStorageSnapshot.measureOffMain(
            dataDirectory: root,
            modelDirectory: models,
            runtimeDirectory: root.appendingPathComponent("mlx-runtime", isDirectory: true)
        )

        XCTAssertEqual(actual, expected)
    }

    func testLogDirectoryIsStable() {
        let first = AfterRayLog.directory
        let second = AfterRayLog.directory
        XCTAssertEqual(first, second)
        XCTAssertEqual(AfterRayLog.fileURL.lastPathComponent, "afterray.log")
    }
}
