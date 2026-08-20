import Foundation

public actor SummaryExportFileStore {
    public static let shared = SummaryExportFileStore()
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    public let directory: URL

    public init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        directory = temporaryRoot.appending(path: "AfterRay-Summary-Exports", directoryHint: .isDirectory)
    }

    public func prepareForLaunch() throws {
        try cleanupAll()
        try ensureDirectory()
    }

    public func write(_ value: SlotSummaryExport) throws -> URL {
        try ensureDirectory()
        try cleanupExpired(now: .now)
        let url = directory.appending(path: "\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // @dec:summary-inline-markdown-actions — docs/decisions/active/product/2026-08-20-summary-inline-markdown-actions.md
    public func write(markdown: String) throws -> URL {
        try ensureDirectory()
        try cleanupExpired(now: .now)
        let url = directory.appending(path: "\(UUID().uuidString).md")
        let contents = markdown.hasSuffix("\n") ? markdown : "\(markdown)\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public func cleanupExpired(now: Date) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if now.timeIntervalSince(values.contentModificationDate ?? .distantPast) > Self.maximumAge {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func cleanupAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
