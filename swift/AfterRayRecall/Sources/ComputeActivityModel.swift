import Foundation

/// What the dashboard needs from whatever is driving it.
///
/// The panel is generic over this so the Visual Lab and previews can drive it
/// from fixtures — every surface in this library has to stay renderable without
/// a daemon.
@MainActor
public protocol ComputeActivityPresenting: ObservableObject {
    var status: ComputeStatus { get }
    var message: String? { get }
    var isApplying: Bool { get }
    /// Advances on every poll, so relative times move even when the report is
    /// byte-identical to the last one.
    var tick: Date { get }
    var indicator: ComputeIndicator { get }

    func startWatching()
    func stopWatching()
    func setMode(_ mode: ComputeMode) async
    func togglePause() async
    func runNow(_ workload: ComputeWorkload) async
}

/// Drives the local-computation dashboard.
///
/// Polls only while something is watching. A dashboard that refreshed forever
/// would itself be background work — sampling every worker process every couple
/// of seconds to tell the user their machine is busy.
@MainActor
public final class ComputeActivityModel: ComputeActivityPresenting {
    @Published public private(set) var status: ComputeStatus = .idle
    @Published public private(set) var message: String?
    @Published public private(set) var isApplying = false
    /// Bumped on every poll so relative times ("running 4s") advance even when
    /// the daemon returns an identical report.
    @Published public private(set) var tick: Date = .init()

    /// Fast enough to feel live, slow enough that the panel is not itself a
    /// load. Each poll walks the queue and samples a handful of pids.
    public static let pollInterval: Duration = .seconds(2)

    /// What the temporary-suspension button asks for.
    public static let pauseSeconds = 3600

    private let daemon: any AfterRayDaemonServing
    private var watchers = 0
    private var pollTask: Task<Void, Never>?

    public init(daemon: any AfterRayDaemonServing) {
        self.daemon = daemon
    }

    public var indicator: ComputeIndicator {
        ComputeIndicator(status: status, now: tick)
    }

    /// Call when the panel appears. Balanced by ``stopWatching``; nested
    /// watchers are counted, so the menu-bar item and the overlay button can
    /// both hold it open without one closing the other's feed.
    public func startWatching() {
        watchers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: ComputeActivityModel.pollInterval)
            }
        }
    }

    public func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        do {
            status = try await daemon.computeStatus()
            message = nil
        } catch {
            message = error.localizedDescription
        }
        tick = Date()
    }

    public func setMode(_ mode: ComputeMode) async {
        await apply { try await self.daemon.setComputeMode(mode) }
    }

    /// Suspends background work for an hour, or resumes it if already suspended
    /// — the button is a toggle because the user's next thought after pausing is
    /// usually "actually, go ahead".
    public func togglePause() async {
        let seconds = status.isPaused(now: Date()) ? 0 : Self.pauseSeconds
        await apply { try await self.daemon.pauseCompute(seconds: seconds) }
    }

    /// Starts one workload's outstanding work immediately.
    public func runNow(_ workload: ComputeWorkload) async {
        await apply { try await self.daemon.runComputeNow(workload: workload) }
    }

    private func apply(_ operation: @Sendable () async throws -> ComputeStatus) async {
        isApplying = true
        do {
            // The daemon answers with the new state, so the panel never shows a
            // switch in a position the daemon does not actually hold.
            status = try await operation()
            message = nil
        } catch {
            message = error.localizedDescription
        }
        tick = Date()
        isApplying = false
    }
}
