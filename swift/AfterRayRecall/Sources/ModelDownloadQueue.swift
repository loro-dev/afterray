import Foundation

/// One row of the settings download queue.
///
/// The daemon reports a single in-flight pack plus the ids waiting behind it.
/// This flattens that into the list the user actually sees, so every surface —
/// the queue itself, the pack rows, the assistant panel — reads the same shape
/// instead of each re-deriving "is this pack busy?" from `ModelDownloadProgress`.
public struct ModelDownloadQueueItem: Identifiable, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case downloading
        case verifying
        case paused
        case waiting
        case failed
    }

    public let id: String
    public let name: String
    public let stage: Stage
    public let bytes: UInt64
    public let expectedBytes: UInt64?
    /// Seconds left, when a transfer rate is known. Verifying and paused rows
    /// have no rate to project from, so they carry `nil` rather than a guess.
    public let etaSeconds: Double?
    public let error: String?

    public init(
        id: String,
        name: String,
        stage: Stage,
        bytes: UInt64 = 0,
        expectedBytes: UInt64? = nil,
        etaSeconds: Double? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.stage = stage
        self.bytes = bytes
        self.expectedBytes = expectedBytes
        self.etaSeconds = etaSeconds
        self.error = error
    }

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(Double(bytes) / Double(expectedBytes), 1)
    }

    public var percent: Int? {
        fraction.map { Int(($0 * 100).rounded(.down)) }
    }

    /// True while the daemon is actively working this pack — the only stage a
    /// pause can act on.
    public var isRunning: Bool { stage == .downloading || stage == .verifying }

    public var canPause: Bool { stage == .downloading }
    public var canResume: Bool { stage == .paused }
    public var canRetry: Bool { stage == .failed }

    public var stageLabel: String {
        switch stage {
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .paused: "Paused"
        case .waiting: "Waiting"
        case .failed: "Failed"
        }
    }

    /// "1.2 GB of 5.97 GB", or just the total while nothing has landed yet.
    public var sizeText: String? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        let total = ModelDownloadQueueItem.byteText(expectedBytes)
        guard stage != .waiting, bytes > 0 else { return total }
        return "\(ModelDownloadQueueItem.byteText(bytes)) of \(total)"
    }

    public var etaText: String? {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds >= 0 else { return nil }
        return "\(ModelDownloadQueueItem.durationText(etaSeconds)) left"
    }

    static func byteText(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Deliberately coarse: a download ETA that ticks "4 min 58 sec" reads as
    /// precision the estimate does not have.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 10 { return "a few seconds" }
        if total < 60 { return "\(total) sec" }
        if total < 3600 {
            let minutes = Int((Double(total) / 60).rounded())
            return minutes <= 1 ? "about a minute" : "\(minutes) min"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}

public extension ModelLibrary {
    /// Flattens the daemon's download state into an ordered queue.
    ///
    /// `bytesPerSecond` is the app's own measurement of the live transfer — the
    /// daemon reports bytes, not speed. Queued rows get a cumulative estimate
    /// (everything ahead of them plus themselves), because the worker runs one
    /// pack at a time and "waiting" with no number is the state the old UI
    /// stranded people in.
    func downloadQueue(bytesPerSecond: Double? = nil) -> [ModelDownloadQueueItem] {
        guard let download else { return [] }
        let rate = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        var items: [ModelDownloadQueueItem] = []
        var remainingAhead = 0.0

        if let stage = ModelLibrary.stage(for: download.state) {
            let expected = download.expectedBytes ?? expectedBytes(forPack: download.packId)
            let remaining = expected.map { Double($0 > download.bytes ? $0 - download.bytes : 0) }
            let eta = stage == .downloading
                ? remaining.flatMap { left in rate.map { left / $0 } }
                : nil
            items.append(
                ModelDownloadQueueItem(
                    id: download.packId,
                    name: packName(forPack: download.packId),
                    stage: stage,
                    bytes: download.bytes,
                    expectedBytes: expected,
                    etaSeconds: eta,
                    error: download.error
                )
            )
            remainingAhead = remaining ?? 0
        }

        for packId in download.queuedPackIds {
            let expected = expectedBytes(forPack: packId)
            remainingAhead += Double(expected ?? 0)
            items.append(
                ModelDownloadQueueItem(
                    id: packId,
                    name: packName(forPack: packId),
                    stage: .waiting,
                    expectedBytes: expected,
                    etaSeconds: expected == nil ? nil : rate.map { remainingAhead / $0 }
                )
            )
        }
        return items
    }

    /// True when the pack is somewhere in the queue, so a caller can disable its
    /// Download and Remove buttons without reaching for a global "busy" flag.
    func isQueued(packID: String) -> Bool {
        guard let download else { return false }
        if download.queuedPackIds.contains(packID) { return true }
        return download.packId == packID && ModelLibrary.stage(for: download.state) != nil
    }

    private static func stage(for state: ModelPackState) -> ModelDownloadQueueItem.Stage? {
        switch state {
        case .downloading: .downloading
        case .verifying: .verifying
        case .paused: .paused
        case .failed: .failed
        case .notDownloaded, .ready, .inUse, .incompatible: nil
        }
    }

    private func packName(forPack packID: String) -> String {
        packs.first { $0.id == packID }?.name ?? packID
    }

    private func expectedBytes(forPack packID: String) -> UInt64? {
        packs.first { $0.id == packID }?.expectedBytes
    }
}
