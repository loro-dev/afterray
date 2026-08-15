import AfterRayRecall
import AppKit
import CryptoKit
import Foundation

/// Installs the bundled `afterray` CLI onto the user's PATH for external agents.
enum AfterRayCliInstall {
    static let binaryName = "afterray"
    static let installDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)

    static var installURL: URL {
        installDirectory.appendingPathComponent(binaryName)
    }

    /// Prefer the app-bundle helper; fall back to a development cargo binary.
    static func sourceBinaryURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(binaryName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("target/release/\(binaryName)"),
            cwd.appendingPathComponent("target/debug/\(binaryName)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installURL.path)
    }

    static var isOnPath: Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        return path.split(separator: ":").contains { segment in
            (segment as NSString).standardizingPath == installDirectory.path
                || FileManager.default.fileExists(
                    atPath: (segment as NSString).appendingPathComponent(binaryName)
                )
        }
    }

    static var statusSummary: String {
        if isInstalled {
            if isOnPath {
                return "Installed at \(installURL.path) and available on PATH."
            }
            return "Installed at \(installURL.path). Add ~/.local/bin to your PATH."
        }
        return "Not installed. Other AI agents cannot call `afterray` yet."
    }

    @discardableResult
    static func install() throws -> URL {
        guard let source = sourceBinaryURL() else {
            throw CliInstallError.sourceMissing
        }
        try FileManager.default.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )
        let destination = installURL
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Copy rather than symlink so the CLI keeps working after rebuilds
        // of a different bundle path (dev vs release).
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: destination.path
        )
        return destination
    }

    static func pathExportLine() -> String {
        #"export PATH="$HOME/.local/bin:$PATH""#
    }

    /// An update moves the bundled CLI on while the copy on PATH stays behind.
    /// The daemon rejects a mismatched protocol version outright, so the user
    /// would see "the CLI suddenly broke" with no hint that reinstalling fixes
    /// it. Refresh silently instead — the copy was installed from this bundle,
    /// so replacing it with this bundle's build is what the user asked for.
    static func refreshIfStale() {
        guard isInstalled, let source = sourceBinaryURL() else { return }
        guard let installed = digest(of: installURL), let bundled = digest(of: source) else {
            return
        }
        guard installed != bundled else { return }
        do {
            try install()
            AfterRayLog.info("refreshed the installed afterray CLI after an update")
        } catch {
            AfterRayLog.info("could not refresh the installed afterray CLI: \(error)")
        }
    }

    private static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum CliInstallError: LocalizedError {
    case sourceMissing

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "Could not find the afterray CLI binary in the app bundle. Rebuild AfterRay and try again."
        }
    }
}
