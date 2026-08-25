import AfterRayRecall
import Darwin
import Foundation

// @dec:bounded-shutdown — docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md
@MainActor
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    let socketPath: String
    let defaultDataDirectory: URL
    let defaultModelDirectory: URL

    var dataDirectory: URL {
        if let overridden = configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") {
            return overridden
        }
        return AfterRayPreferences.memoryDataLocation?.url ?? defaultDataDirectory
    }
    var modelDirectory: URL {
        if let overridden = configuredEnvironmentDirectory("AFTERRAY_MODEL_DIR") {
            return overridden
        }
        if configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil,
           AfterRayPreferences.memoryDataLocation != nil {
            return dataDirectory.appendingPathComponent("Models", isDirectory: true)
        }
        return defaultModelDirectory
    }
    var mlxRuntimeDirectory: URL {
        if configuredEnvironmentDirectory("AFTERRAY_MODEL_DIR") == nil,
           configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil,
           AfterRayPreferences.memoryDataLocation != nil {
            return dataDirectory.appendingPathComponent("mlx-runtime", isDirectory: true)
        }
        return defaultModelDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-runtime", isDirectory: true)
    }

    var repositoryRoot: URL? { Self.developmentRepoRoot() }
    private var process: Process?
    private var processOutput: DaemonOutputBuffer?
    private var recoveryTask: Task<Bool, Error>?
    /// Fence every ordinary keep-alive while a stopped daemon's data root is
    /// being moved. The relocation path is the single permitted restart.
    private var isRelocatingDataDirectory = false
    /// Set only when a failed rollback leaves the old root potentially split
    /// across volumes. This process must not restart capture until the user has
    /// repaired storage and relaunched the app.
    private var requiresDataDirectoryRecovery = false
    private var isSuspendedForSystemLock = false
    private var isStopped = false

    private enum ShutdownDeadline {
        // Covers disposable cancellation, the healthy finite capture drain,
        // required session close, and the short aggregate background join.
        // It is the outer bound if required daemon I/O itself wedges.
        static let graceful: TimeInterval = 6
        static let afterTerminate: TimeInterval = 1.5
        static let afterKill: TimeInterval = 0.5
    }

    /// This control record stays beside, never inside, either data root. The
    /// default vault is `Application Support/AfterRay`; using a sibling keeps
    /// the journal available while that root is crossing a volume boundary.
    private static var relocationRecoveryManifestURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupport
            .appendingPathComponent("AfterRayRelocation", isDirectory: true)
            .appendingPathComponent("memory-location-recovery.json")
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        if let repoRoot = Self.developmentRepoRoot() {
            socketPath = environment["AFTERRAY_SOCKET"]
                ?? AfterRaySocketPath.development(repoRoot: repoRoot)
            defaultDataDirectory = repoRoot.appendingPathComponent(".afterray/v0-data")
            defaultModelDirectory = repoRoot.appendingPathComponent(".afterray/models")
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("AfterRay", isDirectory: true)
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AfterRay")
            socketPath = environment["AFTERRAY_SOCKET"]
                ?? applicationSupport.appendingPathComponent("afterray.sock").path
            defaultDataDirectory = applicationSupport
            defaultModelDirectory = applicationSupport.appendingPathComponent("Models", isDirectory: true)
        }
    }

    @discardableResult
    func startIfNeeded(allowingDataRelocation: Bool = false) async throws -> Bool {
        guard !isStopped else { throw RuntimeError.daemonTerminating }
        guard !requiresDataDirectoryRecovery,
              allowingDataRelocation || !isRelocatingDataDirectory
        else { return false }
        if let recoveryTask {
            return try await recoveryTask.value
        }
        let task = Task { @MainActor in
            try await recoverIfNeeded(allowingDataRelocation: allowingDataRelocation)
        }
        recoveryTask = task
        defer { recoveryTask = nil }
        return try await task.value
    }

    // @dec:vault-location-relocation — docs/decisions/active/architecture/2026-08-20-vault-location-relocation.md
    private func recoverIfNeeded(allowingDataRelocation: Bool) async throws -> Bool {
        guard !isStopped,
              !requiresDataDirectoryRecovery,
              allowingDataRelocation || !isRelocatingDataDirectory
        else { return false }
        let recoveryManifestURL = Self.relocationRecoveryManifestURL
        var currentLocation = configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil
            ? AfterRayPreferences.memoryDataLocation
            : nil
        let startupRecovery: AfterRayDataDirectory.RecoveryPreparation
        do {
            let recoveryCurrentLocation = currentLocation
            startupRecovery = try await Task.detached(priority: .userInitiated) {
                try AfterRayDataDirectory.prepareInterruptedMigration(
                    manifestURL: recoveryManifestURL,
                    currentDataLocation: recoveryCurrentLocation
                )
            }.value
            if case let .restoreSourceLocation(sourceLocation) = startupRecovery {
                // This is intentionally the only main-actor portion: publish
                // and read back the indivisible Location before permitting the
                // background cleanup to remove its crash-recovery fence.
                AfterRayPreferences.memoryDataLocation = sourceLocation
                guard AfterRayPreferences.canonicalMemoryDataLocation == sourceLocation else {
                    throw AfterRayDataDirectory.Error.recoveryRequired(
                        "could not persist the restored source location"
                    )
                }
                try await Task.detached(priority: .userInitiated) {
                    try AfterRayDataDirectory.completeSourceRecovery(
                        manifestURL: recoveryManifestURL,
                        sourceLocation: sourceLocation
                    )
                }.value
            }
        } catch {
            requiresDataDirectoryRecovery = true
            throw error
        }
        // A recovery may have replaced a mixed destination preference. Never
        // continue with the value captured before that durable restore.
        currentLocation = configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil
            ? AfterRayPreferences.canonicalMemoryDataLocation
            : nil
        if let location = currentLocation {
            try AfterRayDataDirectory.validateConfiguredVolume(
                volumeRoot: location.volumeRoot,
                volumeUUID: location.volumeUUID
            )
        }
        if let status = await daemonStatus() {
            if Self.hostBuildMatches(status) {
                await clearRecoveryManifestAfterDaemonVerification(
                    startupRecovery,
                    manifestURL: recoveryManifestURL
                )
                return false
            }
            // An update replaced the bundle while the old daemon kept the
            // socket. Reusing it would run this build's UI against the
            // previous build's logic, against the same store, with nothing
            // visible to the user. Replace it instead.
            AfterRayLog.info(
                "daemon build \(status.hostBuild ?? "unknown") does not match app build "
                    + "\(Self.hostBuild ?? "unknown"); restarting it"
            )
            await terminateDaemon()
        }
        guard !isStopped,
              !requiresDataDirectoryRecovery,
              allowingDataRelocation || !isRelocatingDataDirectory
        else { return false }

        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        }

        let socketURL = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        let daemon = try resolveExecutable(
            environmentKey: "AFTERRAY_DAEMON",
            bundledName: "afterrayd",
            developmentPath: "target/release/afterrayd"
        )
        let child = Process()
        child.executableURL = daemon
        var environment = ProcessInfo.processInfo.environment
        environment["AFTERRAY_SOCKET"] = socketPath
        environment["AFTERRAY_DATA_DIR"] = dataDirectory.path
        environment["AFTERRAY_CAPTURE_SHIM"] = try resolveExecutable(
            environmentKey: "AFTERRAY_CAPTURE_SHIM",
            bundledName: "AfterRayCaptureShim",
            developmentPath: "apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim"
        ).path
        environment["AFTERRAY_NATIVE_MODEL_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_NATIVE_MODEL_WORKER",
            bundledName: "afterray-native-model-worker",
            developmentPath: ".build/release/afterray-native-model-worker"
        ).path
        environment["AFTERRAY_MODEL_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_MODEL_WORKER",
            bundledName: "afterray-model-worker",
            developmentPath: "target/release/afterray-model-worker"
        ).path
        environment["AFTERRAY_MLX_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_MLX_WORKER",
            bundledName: "afterray-mlx-vlm-worker",
            developmentPath: ".build/release/afterray-mlx-vlm-worker"
        ).path
        environment["AFTERRAY_MLX_ASR_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_MLX_ASR_WORKER",
            bundledName: "asr/afterray-mlx-asr-worker",
            developmentPath: "apps/AfterRayMlxAsrWorker/.build/release/afterray-mlx-asr-worker"
        ).path
        environment["AFTERRAY_MODEL_DIR"] = modelDirectory.path
        if let hostBuild = Self.hostBuild {
            environment["AFTERRAY_HOST_BUILD"] = hostBuild
        }
        applyModelDefaults(to: &environment)
        child.environment = environment
        let output = DaemonOutputBuffer()
        child.standardOutput = output.makePipe()
        child.standardError = output.makePipe()
        try child.run()
        if isStopped || requiresDataDirectoryRecovery
            || (!allowingDataRelocation && isRelocatingDataDirectory) {
            child.terminate()
            return false
        }
        process = child
        processOutput = output

        for _ in 0..<150 {
            if isStopped || requiresDataDirectoryRecovery
                || (!allowingDataRelocation && isRelocatingDataDirectory) {
                child.terminate()
                process = nil
                processOutput = nil
                return false
            }
            if await daemonIsReachable() {
                await clearRecoveryManifestAfterDaemonVerification(
                    startupRecovery,
                    manifestURL: recoveryManifestURL
                )
                return true
            }
            if !child.isRunning {
                process = nil
                processOutput = nil
                throw RuntimeError.daemonExited(
                    status: child.terminationStatus,
                    detail: output.summary()
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        child.terminate()
        process = nil
        processOutput = nil
        throw RuntimeError.daemonTimeout(detail: output.summary())
    }

    func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
        terminateOwnedProcess()
        // The daemon owns the socket and removes it only after its active
        // recording session has been closed. A following launch can reuse the
        // still-shutting-down daemon or remove a genuinely stale socket.
    }

    /// Latches the request gate synchronously. The app calls this before it
    /// creates its asynchronous termination task, so no activation/poll task can
    /// sneak a daemon restart into that scheduling gap.
    func beginTermination() {
        guard !isStopped else { return }
        isStopped = true
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// Stops afterrayd and its children, including a daemon this process did
    /// not spawn. Further `startIfNeeded()` calls become no-ops.
    func shutdown() async {
        beginTermination()
        await terminateDaemon()
    }

    /// Stops whoever currently owns the socket without latching `isStopped`,
    /// so a replaced daemon can be followed by a fresh one in the same launch.
    private func terminateDaemon() async {
        let totalStarted = Date.now
        var daemonPid = process?.processIdentifier
        var acknowledged = false
        let rpcStarted = Date.now
        do {
            let result = try await UnixSocketDaemonClient(socketPath: socketPath).shutdown()
            if let pid = result.pid, pid > 1 {
                daemonPid = pid
            }
            acknowledged = true
            AfterRayLog.info(
                "daemon shutdown acknowledged in \(Self.elapsedMilliseconds(since: rpcStarted)) ms"
            )
        } catch {
            AfterRayLog.info(
                "daemon shutdown RPC ended after \(Self.elapsedMilliseconds(since: rpcStarted)) ms: "
                    + error.localizedDescription
            )
        }

        if acknowledged {
            let phaseStarted = Date.now
            if await waitForDaemonExit(pid: daemonPid, timeout: ShutdownDeadline.graceful) {
                AfterRayLog.info(
                    "daemon exited gracefully in \(Self.elapsedMilliseconds(since: phaseStarted)) ms"
                )
                clearOwnedProcess()
                return
            }
            AfterRayLog.info(
                "daemon graceful-exit window timed out after "
                    + "\(Self.elapsedMilliseconds(since: phaseStarted)) ms"
            )
        }

        if let daemonPid, Self.processIsAlive(daemonPid) {
            let phaseStarted = Date.now
            kill(daemonPid, SIGTERM)
            if await waitForDaemonExit(pid: daemonPid, timeout: ShutdownDeadline.afterTerminate) {
                AfterRayLog.info(
                    "daemon exited after SIGTERM in \(Self.elapsedMilliseconds(since: phaseStarted)) ms"
                )
                clearOwnedProcess()
                return
            }
            AfterRayLog.info(
                "daemon SIGTERM window timed out after "
                    + "\(Self.elapsedMilliseconds(since: phaseStarted)) ms"
            )
        }

        if let daemonPid, Self.processIsAlive(daemonPid) {
            let phaseStarted = Date.now
            kill(daemonPid, SIGKILL)
            let exited = await waitForDaemonExit(
                pid: daemonPid,
                timeout: ShutdownDeadline.afterKill
            )
            AfterRayLog.info(
                "daemon SIGKILL \(exited ? "completed" : "did not confirm exit") in "
                    + "\(Self.elapsedMilliseconds(since: phaseStarted)) ms"
            )
        }

        clearOwnedProcess()
        AfterRayLog.info(
            "daemon shutdown path completed in \(Self.elapsedMilliseconds(since: totalStarted)) ms"
        )
    }

    /// Waits on process death or socket removal only. A status request has the
    /// ordinary 30-second receive timeout and must never be part of termination.
    private func waitForDaemonExit(pid: pid_t?, timeout: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if Self.daemonHasExited(pid: pid, socketPath: socketPath) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Self.daemonHasExited(pid: pid, socketPath: socketPath)
    }

    private static func daemonHasExited(pid: pid_t?, socketPath: String) -> Bool {
        if let pid, !processIsAlive(pid) { return true }
        return !FileManager.default.fileExists(atPath: socketPath)
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func elapsedMilliseconds(since started: Date) -> Int {
        Int(Date.now.timeIntervalSince(started) * 1_000)
    }

    private func clearOwnedProcess() {
        process = nil
        processOutput = nil
    }

    private func terminateOwnedProcess() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        processOutput = nil
    }

    var isCapturePausedForSystemLock: Bool { isSuspendedForSystemLock }

    func suspendForSystemLock() {
        guard !isSuspendedForSystemLock else { return }
        isSuspendedForSystemLock = true
    }

    func resumeAfterSystemUnlock() {
        isSuspendedForSystemLock = false
    }

    private func daemonIsReachable() async -> Bool {
        await daemonStatus() != nil
    }

    private func daemonStatus() async -> DaemonStatus? {
        try? await UnixSocketDaemonClient(socketPath: socketPath).status()
    }

    private func clearRecoveryManifestAfterDaemonVerification(
        _ recovery: AfterRayDataDirectory.RecoveryPreparation,
        manifestURL: URL
    ) async {
        guard recovery == .clearAfterDaemonIsReachable else { return }
        do {
            try await Task.detached(priority: .utility) {
                try AfterRayDataDirectory.clearRecoveryManifest(at: manifestURL)
            }.value
        } catch {
            // Keeping a verified journal is safe: the next startup will verify
            // the selected root again before attempting to remove it.
            AfterRayLog.error("could not clear memory relocation journal: \(error.localizedDescription)")
        }
    }

    /// `CFBundleVersion`, which `scripts/build-release.sh` stamps per release.
    /// The marketing version cannot distinguish two builds of one release, and
    /// an update that only fixes the daemon is exactly that case.
    static let hostBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    static func hostBuildMatches(_ status: DaemonStatus) -> Bool {
        // A development tree runs a hand-built daemon whose build number is
        // whatever the placeholder plist says. Restarting it on every app
        // launch would fight the `make dev` workflow.
        if developmentRepoRoot() != nil { return true }
        guard let hostBuild, let running = status.hostBuild else { return false }
        return hostBuild == running
    }

    private func applyModelDefaults(to environment: inout [String: String]) {
        let defaults = [
            "AFTERRAY_ASR_MODEL": modelDirectory
                .appendingPathComponent("Qwen3-ASR-1.7B-MLX-4bit"),
            "AFTERRAY_EMBEDDING_MODEL": modelDirectory
                .appendingPathComponent("nomic-embed-text-v1.5.Q4_K_M.gguf"),
        ]
        for (key, url) in defaults where environment[key] == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                environment[key] = url.path
            }
        }
    }

    /// Stops capture before moving any bytes. The preference changes only after
    /// every move succeeds. A failed rollback leaves the daemon stopped rather
    /// than writing an incomplete source vault.
    // @dec:vault-location-relocation — docs/decisions/active/architecture/2026-08-20-vault-location-relocation.md
    func relocateDataDirectory(to selectedDirectory: URL, migrateExistingData: Bool) async throws {
        guard !requiresDataDirectoryRecovery else {
            throw RuntimeError.dataDirectoryRecoveryRequired
        }
        guard configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil,
              configuredEnvironmentDirectory("AFTERRAY_MODEL_DIR") == nil
        else {
            throw RuntimeError.dataDirectoryManagedByEnvironment
        }

        let destination = AfterRayDataDirectory.destination(in: selectedDirectory)
        let sourceData = dataDirectory
        let sourceModels = modelDirectory
        let sourceRuntime = mlxRuntimeDirectory
        try AfterRayDataDirectory.validateDestination(destination, currentDirectory: sourceData)
        let location = try AfterRayDataDirectory.location(for: destination)
        let sourceLocation = try AfterRayDataDirectory.location(for: sourceData)
        let previousLocation = AfterRayPreferences.memoryDataLocation
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        let recoveryManifestURL = Self.relocationRecoveryManifestURL
        var moves: [AfterRayDataDirectory.Move] = []
        var migrationFinished = false

        guard !isRelocatingDataDirectory else { return }
        isRelocatingDataDirectory = true
        defer { isRelocatingDataDirectory = false }

        // A keep-alive that began immediately before the fence must finish
        // before we stop the daemon. All new keep-alives return while fenced.
        if let recoveryTask {
            _ = try? await recoveryTask.value
        }
        await terminateDaemon()
        do {
            if migrateExistingData {
                // This synchronous write is intentionally before the detached
                // first move; it is the crash/restart fence for cross-volume IO.
                try AfterRayDataDirectory.beginMigration(
                    sourceRoot: sourceData,
                    destinationRoot: destination,
                    sourceLocation: sourceLocation,
                    destinationLocation: location,
                    manifestURL: recoveryManifestURL
                )
                // `FileManager.moveItem` may copy tens of gigabytes across a
                // volume. Keep AppKit and the progress indicator responsive.
                moves = try await Task.detached(priority: .userInitiated) {
                    try AfterRayDataDirectory.migrate(
                        sourceData: sourceData,
                        sourceModels: sourceModels,
                        sourceRuntime: sourceRuntime,
                        destination: destination,
                        socketName: socketName,
                        recoveryManifestURL: recoveryManifestURL
                    )
                }.value
                migrationFinished = true
            }

            AfterRayPreferences.memoryDataLocation = location
            if migrateExistingData {
                try AfterRayDataDirectory.markPreferenceCommitted(
                    at: recoveryManifestURL,
                    location: AfterRayPreferences.canonicalMemoryDataLocation
                )
            }
            _ = try await startIfNeeded(allowingDataRelocation: true)
        } catch {
            AfterRayPreferences.memoryDataLocation = previousLocation
            var recoveryError: (any Swift.Error)?
            if migrationFinished {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try AfterRayDataDirectory.rollback(
                            moves,
                            manifestURL: recoveryManifestURL
                        )
                    }.value
                } catch {
                    recoveryError = error
                }
            }
            if recoveryError == nil, !AfterRayDataDirectory.needsManualRecovery(error) {
                _ = try? await startIfNeeded(allowingDataRelocation: true)
            }
            if let recoveryError {
                requiresDataDirectoryRecovery = true
                throw recoveryError
            }
            if AfterRayDataDirectory.needsManualRecovery(error) {
                requiresDataDirectoryRecovery = true
            }
            throw error
        }
    }

    func relocationDestination(in selectedDirectory: URL) throws -> URL {
        guard configuredEnvironmentDirectory("AFTERRAY_DATA_DIR") == nil,
              configuredEnvironmentDirectory("AFTERRAY_MODEL_DIR") == nil
        else {
            throw RuntimeError.dataDirectoryManagedByEnvironment
        }
        let destination = AfterRayDataDirectory.destination(in: selectedDirectory)
        try AfterRayDataDirectory.validateDestination(destination, currentDirectory: dataDirectory)
        _ = try AfterRayDataDirectory.location(for: destination)
        return destination
    }

    private static func developmentRepoRoot() -> URL? {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard bundleParent.lastPathComponent == ".afterray-dev" else { return nil }
        return bundleParent.deletingLastPathComponent()
    }

    private func configuredEnvironmentDirectory(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return path == parentPath || path.hasPrefix(parentPath + "/")
    }

    private func resolveExecutable(
        environmentKey: String,
        bundledName: String,
        developmentPath: String
    ) throws -> URL {
        if let configured = ProcessInfo.processInfo.environment[environmentKey] {
            return URL(fileURLWithPath: configured)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(bundledName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(developmentPath)
        if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        throw RuntimeError.missingExecutable(bundledName)
    }
}

enum RuntimeError: LocalizedError, Equatable {
    case missingExecutable(String)
    case daemonExited(status: Int32, detail: String)
    case daemonTimeout(detail: String)
    case daemonSuspended
    case daemonTerminating
    case dataDirectoryManagedByEnvironment
    case dataDirectoryRecoveryRequired

    var isUserVisibleFailure: Bool {
        switch self {
        case .daemonSuspended, .daemonTerminating: false
        default: true
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            "AfterRay helper is missing: \(name)"
        case .daemonExited(let status, let detail):
            Self.formatted(headline: "afterrayd exited during startup (status \(status)).", detail: detail)
        case .daemonTimeout(let detail):
            Self.formatted(
                headline: "afterrayd did not become ready. If macOS asked to use the Keychain, click Allow and try again.",
                detail: detail
            )
        case .daemonSuspended:
            "afterrayd is paused while this Mac is locked or asleep."
        case .daemonTerminating:
            "afterrayd is stopping with AfterRay."
        case .dataDirectoryManagedByEnvironment:
            "The memory location is controlled by an environment setting."
        case .dataDirectoryRecoveryRequired:
            "Memory storage needs repair after an incomplete move. Repair the folders, then relaunch AfterRay."
        }
    }

    private static func formatted(headline: String, detail: String) -> String {
        detail.isEmpty ? headline : "\(headline)\n\n\(detail)"
    }
}

private final class DaemonOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pipes: [Pipe] = []
    private let limit = 16 * 1_024

    func makePipe() -> Pipe {
        let pipe = Pipe()
        pipes.append(pipe)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) {
                AfterRayLog.appendRaw(text, source: "afterrayd")
            }
        }
        return pipe
    }

    func summary() -> String {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            append(pipe.fileHandleForReading.availableData)
        }
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data.removeSubrange(..<(data.count - limit))
        }
    }
}
