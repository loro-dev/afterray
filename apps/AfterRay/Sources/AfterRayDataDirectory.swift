import Foundation

/// The user-selected root is deliberately outside the vault's `settings.json`.
/// The daemon must know where to open the vault *before* it can read that file.
enum AfterRayDataDirectory {
    static let folderName = "AfterRay"

    struct Location: Codable, Equatable, Sendable {
        let url: URL
        let volumeRoot: URL
        let volumeUUID: String?
    }

    struct Move: Codable, Equatable, Hashable, Sendable {
        let source: URL
        let destination: URL
    }

    /// Stored outside both data roots so a cross-volume relocation remains
    /// recoverable after a process crash, forced quit, or power loss.
    struct RecoveryManifest: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case prepared
            case moving
            case moved
            case preferenceCommitted
            case rolledBack
        }

        let sourceRoot: URL
        let destinationRoot: URL
        let sourceVolumeRoot: URL
        let sourceVolumeUUID: String?
        let destinationVolumeRoot: URL
        let destinationVolumeUUID: String?
        var phase: Phase
        /// Intent is written before `moveItem`; completion is written after it.
        /// Recovery examines both lists because a crash can occur in between.
        var plannedMoves: [Move]
        var completedMoves: [Move]
    }

    enum StartupRecovery: Equatable, Sendable {
        case none
        /// The new root has every entry and preferences select it. The caller
        /// must clear the manifest only after the new daemon answers status.
        case clearAfterDaemonIsReachable
    }

    enum Error: LocalizedError, Sendable {
        case destinationIsCurrent
        case destinationInsideCurrent
        case destinationIsNotEmpty(URL)
        case configuredVolumeUnavailable(URL)
        case configuredVolumeChanged(URL)
        case rollbackFailed(String)
        case recoveryRequired(String)

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
            case let .recoveryRequired(details):
                "Memory-location recovery needs attention: \(details)"
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

    // @dec:vault-location-relocation — docs/decisions/active/architecture/2026-08-20-vault-location-relocation.md
    /// Creates and synchronizes the recovery record before the first byte move.
    static func beginMigration(
        sourceRoot: URL,
        destinationRoot: URL,
        sourceLocation: Location,
        destinationLocation: Location,
        manifestURL: URL
    ) throws {
        try saveManifest(
            RecoveryManifest(
                sourceRoot: sourceRoot.standardizedFileURL,
                destinationRoot: destinationRoot.standardizedFileURL,
                sourceVolumeRoot: sourceLocation.volumeRoot,
                sourceVolumeUUID: sourceLocation.volumeUUID,
                destinationVolumeRoot: destinationLocation.volumeRoot,
                destinationVolumeUUID: destinationLocation.volumeUUID,
                phase: .prepared,
                plannedMoves: [],
                completedMoves: []
            ),
            at: manifestURL
        )
    }

    static func loadRecoveryManifest(at manifestURL: URL) throws -> RecoveryManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(RecoveryManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw Error.recoveryRequired("could not read \(manifestURL.path): \(error.localizedDescription)")
        }
    }

    /// Runs before daemon startup. An incomplete move is deterministically
    /// returned to the source root; any inaccessible or ambiguous path state
    /// fails closed. A completed move remains journaled until the new daemon
    /// has proved it can open the selected root.
    static func recoverInterruptedMigration(
        manifestURL: URL,
        currentDataDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> StartupRecovery {
        guard var manifest = try loadRecoveryManifest(at: manifestURL) else { return .none }
        try validateConfiguredVolume(
            volumeRoot: manifest.sourceVolumeRoot,
            volumeUUID: manifest.sourceVolumeUUID,
            fileManager: fileManager
        )
        try validateConfiguredVolume(
            volumeRoot: manifest.destinationVolumeRoot,
            volumeUUID: manifest.destinationVolumeUUID,
            fileManager: fileManager
        )

        switch manifest.phase {
        case .preferenceCommitted:
            guard sameDirectory(currentDataDirectory, manifest.destinationRoot) else {
                throw Error.recoveryRequired("preferences do not select the completed destination")
            }
            try requireDestinationComplete(manifest, fileManager: fileManager)
            return .clearAfterDaemonIsReachable

        case .moved:
            if sameDirectory(currentDataDirectory, manifest.destinationRoot) {
                manifest.phase = .preferenceCommitted
                try saveManifest(manifest, at: manifestURL)
                try requireDestinationComplete(manifest, fileManager: fileManager)
                return .clearAfterDaemonIsReachable
            }
            try rollbackManifest(&manifest, manifestURL: manifestURL, fileManager: fileManager)

        case .prepared, .moving:
            try rollbackManifest(&manifest, manifestURL: manifestURL, fileManager: fileManager)

        case .rolledBack:
            try requireSourceRestored(manifest, fileManager: fileManager)
        }

        try clearRecoveryManifest(at: manifestURL, fileManager: fileManager)
        return .none
    }

    static func markPreferenceCommitted(at manifestURL: URL) throws {
        guard var manifest = try loadRecoveryManifest(at: manifestURL) else {
            throw Error.recoveryRequired("migration manifest disappeared before preferences were committed")
        }
        manifest.phase = .preferenceCommitted
        try saveManifest(manifest, at: manifestURL)
    }

    static func clearRecoveryManifest(
        at manifestURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        try fileManager.removeItem(at: manifestURL)
    }

    @discardableResult
    static func moveContents(
        from source: URL,
        to destination: URL,
        excluding names: Set<String> = [],
        fileManager: FileManager = .default,
        journal: RecoveryJournal? = nil
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
                let move = Move(source: entry, destination: target)
                try journal?.recordIntent(move)
                try fileManager.moveItem(at: entry, to: target)
                try journal?.recordCompletion(move)
                moves.append(move)
            }
            return moves
        } catch {
            if journal == nil {
                try rollback(moves, fileManager: fileManager)
            }
            throw error
        }
    }

    @discardableResult
    static func moveDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default,
        journal: RecoveryJournal? = nil
    ) throws -> Move? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw Error.destinationIsNotEmpty(destination.deletingLastPathComponent())
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let move = Move(source: source, destination: destination)
        try journal?.recordIntent(move)
        try fileManager.moveItem(at: source, to: destination)
        try journal?.recordCompletion(move)
        return move
    }

    /// A complete move transaction, including the separately located development
    /// model/runtime directories. The caller must leave the daemon stopped for
    /// its entire duration.
    static func migrate(
        sourceData: URL,
        sourceModels: URL,
        sourceRuntime: URL,
        destination: URL,
        socketName: String,
        recoveryManifestURL: URL? = nil
    ) throws -> [Move] {
        let journal = try recoveryManifestURL.map { try RecoveryJournal(manifestURL: $0) }
        try journal?.markMoving()
        var moves: [Move] = []
        do {
            moves += try moveContents(
                from: sourceData,
                to: destination,
                excluding: [socketName],
                journal: journal
            )
            if !isDescendant(sourceModels, of: sourceData),
               let move = try moveDirectory(
                   from: sourceModels,
                   to: destination.appendingPathComponent("Models", isDirectory: true),
                   journal: journal
               ) {
                moves.append(move)
            }
            if !isDescendant(sourceRuntime, of: sourceData),
               !isDescendant(sourceRuntime, of: sourceModels),
               let move = try moveDirectory(
                   from: sourceRuntime,
                   to: destination.appendingPathComponent("mlx-runtime", isDirectory: true),
                   journal: journal
               ) {
                moves.append(move)
            }
            try journal?.markMoved()
            return moves
        } catch {
            if journal != nil {
                // Include prewritten intents: a manifest write can succeed just
                // before `moveItem` succeeds but before completion is recorded.
                _ = try recoverInterruptedMigration(
                    manifestURL: recoveryManifestURL!,
                    currentDataDirectory: sourceData
                )
            } else {
                try rollback(moves)
            }
            throw error
        }
    }

    static func rollback(
        _ moves: [Move],
        manifestURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        var failures: [String] = []
        for move in moves.reversed() {
            switch (pathState(at: move.source, fileManager: fileManager),
                    pathState(at: move.destination, fileManager: fileManager)) {
            case (.present, .missing):
                continue
            case (.missing, .present):
                do {
                    try fileManager.moveItem(at: move.destination, to: move.source)
                    guard case (.present, .missing) = (
                        pathState(at: move.source, fileManager: fileManager),
                        pathState(at: move.destination, fileManager: fileManager)
                    ) else {
                        throw Error.rollbackFailed("did not restore \(move.source.path)")
                    }
                } catch {
                    failures.append("\(move.destination.path): \(error.localizedDescription)")
                }
            default:
                failures.append("\(move.source.path) / \(move.destination.path): "
                    + "expected source present and destination absent after rollback")
            }
        }
        if !failures.isEmpty {
            throw Error.rollbackFailed(failures.joined(separator: "; "))
        }
        if let manifestURL {
            guard var manifest = try loadRecoveryManifest(at: manifestURL) else {
                throw Error.recoveryRequired("migration manifest disappeared during rollback")
            }
            manifest.phase = .rolledBack
            try saveManifest(manifest, at: manifestURL)
        }
    }

    static func needsManualRecovery(_ error: any Swift.Error) -> Bool {
        guard let error = error as? Error else { return false }
        return switch error {
        case .rollbackFailed, .recoveryRequired:
            true
        default:
            false
        }
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

    /// Mutable journal kept private to the background migration task. Every
    /// mutation writes and synchronizes the complete manifest before returning.
    final class RecoveryJournal: @unchecked Sendable {
        private let manifestURL: URL
        private var manifest: RecoveryManifest

        init(manifestURL: URL) throws {
            self.manifestURL = manifestURL
            guard let manifest = try loadRecoveryManifest(at: manifestURL) else {
                throw Error.recoveryRequired("migration manifest disappeared before moving data")
            }
            self.manifest = manifest
        }

        var completedMoves: [Move] { manifest.completedMoves }

        func markMoving() throws {
            manifest.phase = .moving
            try saveManifest(manifest, at: manifestURL)
        }

        func recordIntent(_ move: Move) throws {
            manifest.plannedMoves.append(move)
            try saveManifest(manifest, at: manifestURL)
        }

        func recordCompletion(_ move: Move) throws {
            manifest.completedMoves.append(move)
            try saveManifest(manifest, at: manifestURL)
        }

        func markMoved() throws {
            manifest.phase = .moved
            try saveManifest(manifest, at: manifestURL)
        }

        func markRolledBack() throws {
            manifest.phase = .rolledBack
            try saveManifest(manifest, at: manifestURL)
        }
    }

    private enum PathState {
        case present
        case missing
        case inaccessible
    }

    private static func rollbackManifest(
        _ manifest: inout RecoveryManifest,
        manifestURL: URL,
        fileManager: FileManager
    ) throws {
        // Planned entries include the small window between prewriting intent and
        // FileManager completing its cross-volume move. De-duplicate without
        // changing move order, then reverse in `rollback`.
        let moves = uniqueMoves(manifest.plannedMoves + manifest.completedMoves)
        try rollback(moves, fileManager: fileManager)
        manifest.phase = .rolledBack
        try saveManifest(manifest, at: manifestURL)
        try requireSourceRestored(manifest, fileManager: fileManager)
    }

    private static func requireDestinationComplete(
        _ manifest: RecoveryManifest,
        fileManager: FileManager
    ) throws {
        for move in uniqueMoves(manifest.plannedMoves + manifest.completedMoves) {
            guard case (.missing, .present) = (
                pathState(at: move.source, fileManager: fileManager),
                pathState(at: move.destination, fileManager: fileManager)
            ) else {
                throw Error.recoveryRequired("destination is incomplete at \(move.destination.path)")
            }
        }
    }

    private static func requireSourceRestored(
        _ manifest: RecoveryManifest,
        fileManager: FileManager
    ) throws {
        for move in uniqueMoves(manifest.plannedMoves + manifest.completedMoves) {
            guard case (.present, .missing) = (
                pathState(at: move.source, fileManager: fileManager),
                pathState(at: move.destination, fileManager: fileManager)
            ) else {
                throw Error.recoveryRequired("source was not restored at \(move.source.path)")
            }
        }
    }

    private static func uniqueMoves(_ moves: [Move]) -> [Move] {
        var seen = Set<Move>()
        return moves.filter { seen.insert($0).inserted }
    }

    private static func pathState(at url: URL, fileManager: FileManager) -> PathState {
        if fileManager.fileExists(atPath: url.path) {
            return .present
        }
        // `fileExists` intentionally returns false for an unavailable mount as
        // well as a missing path. Prove the containing directory remains
        // readable before treating that answer as an actual absence.
        let parent = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else {
            return .inaccessible
        }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: parent.path)
            return names.contains(url.lastPathComponent) ? .inaccessible : .missing
        } catch {
            return .inaccessible
        }
    }

    private static func saveManifest(_ manifest: RecoveryManifest, at url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(manifest)
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw Error.recoveryRequired("could not create \(temporary.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return path.hasPrefix(parentPath + "/")
    }
}
