import Foundation

/// The user-selected root is deliberately outside the vault's `settings.json`.
/// The daemon must know where to open the vault *before* it can read that file.
enum AfterRayDataDirectory {
    static let folderName = "AfterRay"

    struct Location: Equatable, Sendable {
        let url: URL
        let volumeRoot: URL
        let volumeUUID: String?
    }

    struct Move: Equatable, Sendable {
        let source: URL
        let destination: URL
    }

    enum Error: LocalizedError, Sendable {
        case destinationIsCurrent
        case destinationInsideCurrent
        case destinationIsNotEmpty(URL)
        case configuredVolumeUnavailable(URL)
        case configuredVolumeChanged(URL)
        case rollbackFailed(String)

        var errorDescription: String? {
            switch self {
            case .destinationIsCurrent:
                "This folder already stores your memories."
            case .destinationInsideCurrent:
                "Choose a folder outside the current memory location."
            case let .destinationIsNotEmpty(directory):
                "\(directory.path) already contains files. Choose an empty folder."
            case let .configuredVolumeUnavailable(volume):
                "The drive containing your memories is unavailable: \(volume.path)"
            case let .configuredVolumeChanged(volume):
                "The drive at \(volume.path) is not the drive that stores your memories."
            case let .rollbackFailed(details):
                "Could not restore the original memory location: \(details)"
            }
        }
    }

    static func destination(in selectedDirectory: URL) -> URL {
        selectedDirectory
            .standardizedFileURL
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func location(for destination: URL) throws -> Location {
        let destination = destination.standardizedFileURL
        let volumeProbe = FileManager.default.fileExists(atPath: destination.path)
            ? destination
            : destination.deletingLastPathComponent()
        let values = try volumeProbe.resourceValues(forKeys: [
            .volumeURLKey,
            .volumeUUIDStringKey,
        ])
        return Location(
            url: destination,
            volumeRoot: (
                values.allValues[.volumeURLKey] as? URL ?? destination
            ).standardizedFileURL,
            volumeUUID: values.volumeUUIDString
        )
    }

    static func validateDestination(
        _ destination: URL,
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let destination = destination.standardizedFileURL
        let current = currentDirectory.standardizedFileURL
        if destination == current {
            throw Error.destinationIsCurrent
        }
        if isDescendant(destination, of: current) {
            throw Error.destinationInsideCurrent
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: []
        )
        if !entries.isEmpty {
            throw Error.destinationIsNotEmpty(destination)
        }
    }

    static func hasContents(
        at directory: URL,
        excluding names: Set<String> = [],
        fileManager: FileManager = .default
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return entries.contains { !names.contains($0.lastPathComponent) }
    }

    @discardableResult
    static func moveContents(
        from source: URL,
        to destination: URL,
        excluding names: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> [Move] {
        guard fileManager.fileExists(atPath: source.path) else { return [] }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        var moves: [Move] = []
        do {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where !names.contains(entry.lastPathComponent) {
                let target = destination.appendingPathComponent(entry.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else {
                    throw Error.destinationIsNotEmpty(destination)
                }
                try fileManager.moveItem(at: entry, to: target)
                moves.append(Move(source: entry, destination: target))
            }
            return moves
        } catch {
            try rollback(moves, fileManager: fileManager)
            throw error
        }
    }

    @discardableResult
    static func moveDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Move? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw Error.destinationIsNotEmpty(destination.deletingLastPathComponent())
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: source, to: destination)
        return Move(source: source, destination: destination)
    }

    /// A complete move transaction, including the separately located development
    /// model/runtime directories. The caller must leave the daemon stopped for
    /// its entire duration.
    static func migrate(
        sourceData: URL,
        sourceModels: URL,
        sourceRuntime: URL,
        destination: URL,
        socketName: String
    ) throws -> [Move] {
        var moves: [Move] = []
        do {
            moves += try moveContents(
                from: sourceData,
                to: destination,
                excluding: [socketName]
            )
            if !isDescendant(sourceModels, of: sourceData),
               let move = try moveDirectory(
                   from: sourceModels,
                   to: destination.appendingPathComponent("Models", isDirectory: true)
               ) {
                moves.append(move)
            }
            if !isDescendant(sourceRuntime, of: sourceData),
               !isDescendant(sourceRuntime, of: sourceModels),
               let move = try moveDirectory(
                   from: sourceRuntime,
                   to: destination.appendingPathComponent("mlx-runtime", isDirectory: true)
               ) {
                moves.append(move)
            }
            return moves
        } catch {
            try rollback(moves)
            throw error
        }
    }

    static func rollback(_ moves: [Move], fileManager: FileManager = .default) throws {
        var failures: [String] = []
        for move in moves.reversed() where fileManager.fileExists(atPath: move.destination.path) {
            do {
                try fileManager.moveItem(at: move.destination, to: move.source)
            } catch {
                failures.append("\(move.destination.path): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw Error.rollbackFailed(failures.joined(separator: "; "))
        }
    }

    static func needsManualRecovery(_ error: any Swift.Error) -> Bool {
        guard let error = error as? Error else { return false }
        if case .rollbackFailed = error { return true }
        return false
    }

    static func validateConfiguredVolume(
        volumeRoot: URL,
        volumeUUID: String?,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: volumeRoot.path) else {
            throw Error.configuredVolumeUnavailable(volumeRoot)
        }
        guard let volumeUUID else { return }
        let current = try volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard current == volumeUUID else {
            throw Error.configuredVolumeChanged(volumeRoot)
        }
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return path.hasPrefix(parentPath + "/")
    }
}
