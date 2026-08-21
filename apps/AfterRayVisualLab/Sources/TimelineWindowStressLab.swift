import AfterRayMockData
import AfterRayRecall
import Foundation
import OSLog
import SwiftUI

/// Production-shaped scroll benchmark: seven queried local days contain about
/// the same 26K lean-index rows as a real vault, and crossing midnight fetches
/// the eighth day through `RecallStore.extendTimeline` with daemon-like delay.
struct TimelineWindowStressLab: View {
    @StateObject private var store: RecallStore
    @State private var isLive = false
    private let anchorMs: Int64

    @MainActor
    init() {
        let fixture = TimelineWindowStressFixture.make()
        anchorMs = fixture.anchorMs
        _store = StateObject(
            wrappedValue: RecallStore(
                daemon: TimelineWindowStressDaemon(moments: fixture.moments)
            )
        )
    }

    var body: some View {
        RecallView(
            moments: store.moments,
            timelineRevision: store.timelineRevision,
            timelineSpine: store.timelineSpine,
            timelineDayCoverage: store.timelineDayCoverage,
            playheadMs: Binding(
                get: { store.playheadMs },
                set: { store.select(playheadMs: $0) }
            ),
            isLive: $isLive,
            loadState: store.loadState,
            imageLoader: MockArtifactFactory.loader,
            onApproachTimelineEdge: { direction, playheadMs in
                await store.extendTimeline(direction: direction, aroundMs: playheadMs)
            }
        )
        .task {
            guard store.moments.isEmpty else { return }
            await store.loadTimeline(containingMs: anchorMs)
            store.select(playheadMs: anchorMs)
        }
    }
}

private struct TimelineWindowStressFixture: Sendable {
    let anchorMs: Int64
    let moments: [RecallMoment]

    static func make() -> Self {
        let today = DaySummaryLayout.dayBounds(
            ms: Int64(Date.now.timeIntervalSince1970 * 1_000)
        )
        var center = today
        for _ in 0..<4 {
            center = DaySummaryLayout.dayBounds(ms: center.start - 1)
        }
        // Start just before midnight so the automated forward flick crosses a
        // day, then its reverse crosses back. Both outer-day publications land
        // during active inertia rather than after the benchmark has settled.
        let anchorMs = center.end - 30 * 60 * 1_000
        let applications = [
            ("Figma", "com.figma.Desktop"),
            ("Safari", "com.apple.Safari"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Slack", "com.tinyspeck.slackmacgap"),
        ]
        var moments: [RecallMoment] = []
        moments.reserveCapacity(9 * 3_800)
        var globalIndex = 0
        for dayOffset in -4...4 {
            var day = center
            if dayOffset < 0 {
                for _ in dayOffset..<0 {
                    day = DaySummaryLayout.dayBounds(ms: day.start - 1)
                }
            } else if dayOffset > 0 {
                for _ in 0..<dayOffset {
                    day = DaySummaryLayout.dayBounds(ms: day.end)
                }
            }
            for index in 0..<3_800 {
                let app = applications[(index / 90) % applications.count]
                let segment = globalIndex / 12
                moments.append(
                    RecallMoment(
                        id: "window-stress-\(globalIndex)",
                        sessionId: "window-stress-session",
                        capturedAtMs: day.start + 10_000 + Int64(index) * 20_000,
                        gop: RecallGopRef(
                            segmentId: "mock-segment-\(segment)",
                            index: UInt16(globalIndex % 12),
                            frameCount: 12
                        ),
                        applicationName: app.0,
                        bundleIdentifier: app.1,
                        windowTitle: "Seven-day window · \(globalIndex)"
                    )
                )
                globalIndex += 1
            }
        }
        return Self(anchorMs: anchorMs, moments: moments)
    }
}

private actor TimelineWindowStressDaemon: RecallDaemonServing {
    private static let log = Logger(subsystem: "dev.afterray", category: "ui-perf")
    private let moments: [RecallMoment]
    private var rangeRequestCount = 0

    init(moments: [RecallMoment]) {
        self.moments = moments
    }

    func sessions() async throws -> [RecallSession] { [] }

    func timeline() async throws -> [RecallMoment] { moments }

    func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        moments.filter { $0.capturedAtMs >= sinceMs }
    }

    func timeline(fromMs: Int64, toMs: Int64) async throws -> [RecallMoment] {
        try await Task.sleep(for: .milliseconds(60))
        let selected = moments.filter { $0.capturedAtMs >= fromMs && $0.capturedAtMs <= toMs }
        rangeRequestCount += 1
        Self.log.notice(
            "[afterray-window-stress] range_request=\(self.rangeRequestCount) rows=\(selected.count)"
        )
        return selected
    }

    func moments(sessionID: String) async throws -> [RecallMoment] {
        moments.filter { $0.sessionId == sessionID }
    }

    func recallWindow(
        sessionID: String,
        centerMs: Int64,
        limit: Int
    ) async throws -> [RecallMoment] {
        let session = moments.filter { $0.sessionId == sessionID }
        let insertion = session.partitioningIndex { $0.capturedAtMs >= centerMs }
        let start = max(insertion - limit / 2, 0)
        return Array(session.dropFirst(start).prefix(limit))
    }

    func artifact(id: String) async throws -> ArtifactPayload {
        throw DaemonClientError.rejected("stress lab does not read \(id)")
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private extension RandomAccessCollection {
    func partitioningIndex(
        where belongsInSecondPartition: (Element) -> Bool
    ) -> Index {
        var lower = startIndex
        var upper = endIndex
        while lower != upper {
            let distance = distance(from: lower, to: upper)
            let middle = index(lower, offsetBy: distance / 2)
            if belongsInSecondPartition(self[middle]) {
                upper = middle
            } else {
                lower = index(after: middle)
            }
        }
        return lower
    }
}
