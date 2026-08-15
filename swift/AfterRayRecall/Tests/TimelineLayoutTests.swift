import XCTest
@testable import AfterRayRecall

final class TimelineLayoutTests: XCTestCase {
    func testMappingIsInvertibleAcrossInflatedShortRuns() {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)

        var time = layout.startMs
        while time <= layout.endMs {
            let x = layout.x(ms: time)
            XCTAssertEqual(layout.ms(x: x), time, "ms(x(t)) must round-trip at \(time)")
            time += 1_000
        }

        var x: CGFloat = 0
        while x <= layout.contentWidth {
            let ms = layout.ms(x: x)
            XCTAssertEqual(layout.x(ms: ms), x, accuracy: 0.6, "x(ms(x)) must round-trip at \(x)")
            x += 17
        }
    }

    func testNeedleStaysInsideOwnRunWithManyShortAppSwitches() throws {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        XCTAssertGreaterThan(layout.runs.count, 40)

        for moment in moments {
            let runByTime = try XCTUnwrap(layout.run(containingMs: moment.capturedAtMs))
            XCTAssertEqual(runByTime.identity, AppUsageIdentity.of(moment))

            let x = layout.x(ms: moment.capturedAtMs)
            let runByX = try XCTUnwrap(layout.run(atX: x))
            XCTAssertEqual(
                runByX.identity,
                AppUsageIdentity.of(moment),
                "playhead at \(moment.capturedAtMs) sits in \(runByX.applicationName) instead of \(moment.applicationName ?? "?")"
            )
        }
    }

    func testLegacyHStackMinWidthFormulaDesynchronizesNeedleFromRuns() {
        let moments = clusteredShortSwitchesThenLongRun()
        let bounds = TimelineLayout.timeBounds(moments: moments)
        let total = max(bounds.endMs - bounds.startMs, 1)
        let contentWidth: CGFloat = 1_000
        let gap: CGFloat = 2
        let runs = TimelineLayout(moments: moments, viewportWidth: contentWidth, density: 0.12).runs

        var cursor: CGFloat = 0
        var mismatched = 0
        for (index, run) in runs.enumerated() {
            let fraction = CGFloat(run.durationMs) / CGFloat(total)
            let visualWidth = max(contentWidth * fraction - gap, 5)
            let visualStart = cursor
            cursor += visualWidth + (index == runs.count - 1 ? 0 : gap)

            let sample = moments[run.startIndex]
            let timeX = contentWidth * CGFloat(sample.capturedAtMs - bounds.startMs) / CGFloat(total)
            if timeX < visualStart || timeX > visualStart + visualWidth {
                mismatched += 1
            }
        }

        XCTAssertGreaterThan(
            mismatched,
            0,
            "The old HStack + min-width layout must stay observably wrong so we do not bring it back"
        )
    }

    func testHigherDensityWidensALongTimeline() {
        let moments = evenlySpacedMoments(count: 720)
        let compact = TimelineLayout(moments: moments, viewportWidth: 720, density: 0.12)
        let zoomed = TimelineLayout(moments: moments, viewportWidth: 720, density: 0.36)
        XCTAssertGreaterThan(zoomed.contentWidth, compact.contentWidth)
    }

    func testZoomCanWidenPastTheOldNineThousandPointCap() {
        let moments = evenlySpacedMoments(count: 200)
        let zoomed = TimelineLayout(moments: moments, viewportWidth: 720, density: 5.0)
        XCTAssertGreaterThan(zoomed.contentWidth, 9_000)
    }

    func testApplicationNameChangeSplitsRunsWithoutChangingCountOrEndpoints() {
        let first = moment(id: "a", at: 0, app: "Safari", bundle: "safari")
        let middle = moment(id: "b", at: 10_000, app: "Safari", bundle: "safari")
        let last = moment(id: "c", at: 20_000, app: "Safari", bundle: "safari")
        let before = TimelineLayout(
            moments: [first, middle, last],
            viewportWidth: 800,
            density: 0.12
        )
        XCTAssertEqual(before.runs.count, 1)

        let splitMiddle = moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode")
        let after = TimelineLayout(
            moments: [first, splitMiddle, last],
            viewportWidth: 800,
            density: 0.12
        )
        XCTAssertEqual(after.moments.count, before.moments.count)
        XCTAssertEqual(after.moments.first?.id, before.moments.first?.id)
        XCTAssertEqual(after.moments.last?.id, before.moments.last?.id)
        XCTAssertEqual(after.runs.map(\.applicationName), ["Safari", "Xcode", "Safari"])
    }

    func testClickUsesTimeUnderCursorNotRunCenter() throws {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "s2", at: 1_000, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_600_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        let safari = try XCTUnwrap(layout.runs.first)
        let clickX = safari.startX + safari.width * 0.1
        let playheadMs = layout.ms(x: clickX)
        let resolved = try XCTUnwrap(RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments))
        XCTAssertEqual(resolved.applicationName, "Safari")
        XCTAssertNotEqual(resolved.id, moments[safari.startIndex + (safari.endIndex - safari.startIndex) / 2].id)
    }

    func testResolveAndMoveShareOneMomentWithTheNeedle() throws {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        var playheadMs = moments[10].capturedAtMs
        var isLive = false

        let moved = RecallPlayhead.move(
            playheadMs: playheadMs,
            isLive: isLive,
            deltaX: 80,
            layout: layout
        )
        playheadMs = moved.playheadMs
        isLive = moved.isLive

        let resolved = try XCTUnwrap(RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments))
        let needleRun = try XCTUnwrap(layout.run(atX: layout.playheadX(playheadMs: playheadMs, isLive: isLive)))
        XCTAssertEqual(needleRun.identity, AppUsageIdentity.of(resolved))
        XCTAssertEqual(resolved.imageArtifactId, "frame-\(resolved.id)")
        XCTAssertFalse(isLive)
    }

    func testDisplayedFrameKeepsPreviousArtifactUntilTheNextOneArrives() {
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: nil as String?,
                loadedID: "A",
                loadedFrame: "frame-A"
            ),
            "frame-A"
        )
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: "cached-B",
                loadedID: "A",
                loadedFrame: "frame-A"
            ),
            "cached-B"
        )
        XCTAssertEqual(
            RecallDisplayedFrame.choose(
                artifactID: "B",
                cached: nil as String?,
                loadedID: "B",
                loadedFrame: "frame-B"
            ),
            "frame-B"
        )
    }

    func testLeavingLiveMovesByTimelinePointsAndEnteringLiveSnapsToEnd() {
        let moments = [
            moment(id: "a", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 800, density: 0.2)

        let intoHistory = RecallPlayhead.move(
            playheadMs: moments[1].capturedAtMs,
            isLive: true,
            deltaX: 20,
            layout: layout
        )
        XCTAssertFalse(intoHistory.isLive)
        XCTAssertLessThan(intoHistory.playheadMs, layout.endMs)

        let backToNow = RecallPlayhead.move(
            playheadMs: intoHistory.playheadMs,
            isLive: false,
            deltaX: -10_000,
            layout: layout
        )
        XCTAssertTrue(backToNow.isLive)
        XCTAssertEqual(backToNow.playheadMs, moments[1].capturedAtMs)
    }

    func testIdleGapSplitsDistantMomentsAndCapsWidth() {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "s2", at: 10_000, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_610_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        XCTAssertEqual(layout.runs.map(\.isIdle), [false, true, false])
        XCTAssertEqual(layout.runs.map(\.applicationName), ["Safari", "休眠", "Xcode"])
        let idle = layout.runs[1]
        XCTAssertLessThanOrEqual(idle.durationMs, 3_610_000)
        let idleVisualShare = idle.width / layout.contentWidth
        XCTAssertLessThan(idleVisualShare, 0.85, "hour-long lock must not dominate the timeline")
    }

    func testScrubAndClickSkipIdleGaps() {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_600_000, app: "Xcode", bundle: "xcode"),
        ]
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)
        XCTAssertEqual(layout.snapToRecordedMs(60_000, preferring: -1), 0)
        XCTAssertEqual(layout.snapToRecordedMs(60_000, preferring: 1), 3_600_000)

        let forward = RecallPlayhead.move(
            playheadMs: 0,
            isLive: false,
            deltaX: -400,
            layout: layout
        )
        XCTAssertEqual(forward.playheadMs, 3_600_000)

        let backward = RecallPlayhead.move(
            playheadMs: 3_600_000,
            isLive: false,
            deltaX: 400,
            layout: layout
        )
        XCTAssertEqual(backward.playheadMs, 0)
    }

    func testResolveIsNilInsideIdleGap() {
        let moments = [
            moment(id: "s1", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "x1", at: 3_600_000, app: "Xcode", bundle: "xcode"),
        ]
        XCTAssertEqual(RecallPlayhead.resolve(playheadMs: 0, moments: moments)?.id, "s1")
        XCTAssertNil(RecallPlayhead.resolve(playheadMs: 60_000, moments: moments))
        XCTAssertEqual(RecallPlayhead.resolve(playheadMs: 3_600_000, moments: moments)?.id, "x1")
    }

    func testStepMomentUsesDiscreteSamples() {
        let moments = [
            moment(id: "a", at: 0, app: "Safari", bundle: "safari"),
            moment(id: "b", at: 10_000, app: "Xcode", bundle: "xcode"),
        ]
        let fromLive = RecallPlayhead.stepMoment(
            playheadMs: 10_000,
            isLive: true,
            delta: -1,
            moments: moments
        )
        XCTAssertFalse(fromLive.isLive)
        XCTAssertEqual(fromLive.playheadMs, 10_000)

        let toLive = RecallPlayhead.stepMoment(
            playheadMs: 10_000,
            isLive: false,
            delta: 1,
            moments: moments
        )
        XCTAssertTrue(toLive.isLive)
    }

    // MARK: - Scroll-path optimisations
    //
    // Lookup, culling and caching were rewritten to stop a scroll tick from
    // re-scanning the whole day. These pin the behaviour that rewrite must
    // preserve; the reference implementations below are the code they replaced.

    func testBinarySearchAgreesWithTheLinearScanItReplaced() {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 1_000, density: 0.12)

        var time = layout.startMs - 5_000
        while time <= layout.endMs + 5_000 {
            XCTAssertEqual(
                layout.run(containingMs: time)?.id,
                linearRun(containingMs: time, in: layout.runs)?.id,
                "run lookup diverged at \(time)"
            )
            XCTAssertEqual(
                RecallPlayhead.resolveIndex(playheadMs: time, moments: moments),
                linearResolveIndex(playheadMs: time, moments: moments),
                "playhead index diverged at \(time)"
            )
            time += 250
        }

        var x = -40 as CGFloat
        while x <= layout.contentWidth + 40 {
            XCTAssertEqual(
                layout.run(atX: x)?.id,
                linearRun(atX: x, in: layout.runs)?.id,
                "run-at-x diverged at \(x)"
            )
            x += 3
        }
    }

    /// The track is wider than the screen by a large factor. Drawing only the
    /// visible slice is the point — but it must be the *whole* visible slice,
    /// or segments pop in at the edges while scrolling.
    func testVisibleSliceCoversTheRangeAndNothingElse() {
        let moments = evenlySpacedMoments(count: 900)
        let layout = TimelineLayout(moments: moments, viewportWidth: 900, density: 4)
        XCTAssertGreaterThan(layout.contentWidth, 3_000)

        for start in stride(from: CGFloat(0), through: layout.contentWidth, by: 137) {
            let range = start...(start + 600)
            let slice = layout.runs(intersecting: range)
            let expected = layout.runs.filter { $0.startX <= range.upperBound && $0.endX >= range.lowerBound }
            XCTAssertEqual(
                slice.map(\.id),
                expected.map(\.id),
                "culled slice at \(start) is not the set of runs touching the range"
            )
        }
    }

    func testEveryRunIsDrawnAtLeastOnceAcrossAFullScroll() {
        let moments = clusteredShortSwitchesThenLongRun()
        let layout = TimelineLayout(moments: moments, viewportWidth: 300, density: 2)
        var seen = Set<Int>()
        for centre in stride(from: CGFloat(0), through: layout.contentWidth, by: 25) {
            seen.formUnion(layout.runs(intersecting: (centre - 150)...(centre + 150)).map(\.id))
        }
        XCTAssertEqual(seen.count, layout.runs.count, "scrolling past a run must draw it")
    }

    func testFavouritesArePlacedWhereTheTimeMapsThem() {
        var moments = evenlySpacedMoments(count: 40)
        moments[3].isFavorite = true
        moments[21].isFavorite = true
        let layout = TimelineLayout(moments: moments, viewportWidth: 800, density: 0.4)

        XCTAssertEqual(layout.favorites.map(\.id), ["m3", "m21"])
        for favorite in layout.favorites {
            let moment = try? XCTUnwrap(moments.first { $0.id == favorite.id })
            XCTAssertEqual(favorite.x, layout.x(ms: moment?.capturedAtMs ?? 0), accuracy: 0.001)
        }
    }

    /// The layout was a computed property, so one scroll tick built it three
    /// times. It must now survive a frame untouched, and still notice every
    /// input that genuinely changes it.
    func testCacheRebuildsOnlyWhenAnInputChanges() {
        let moments = evenlySpacedMoments(count: 300)
        let cache = TimelineLayoutCache()

        let first = cache.layout(moments: moments, viewportWidth: 800, density: 0.12)
        // A scroll tick reads the layout three times. None of them may rebuild.
        for _ in 0..<300 {
            _ = cache.layout(moments: moments, viewportWidth: 800, density: 0.12)
        }
        XCTAssertEqual(cache.scans, 1, "a steady scroll must not rescan the captures")
        XCTAssertEqual(cache.placements, 1, "a steady scroll must not re-place the runs")

        let zoomed = cache.layout(moments: moments, viewportWidth: 800, density: 0.48)
        XCTAssertGreaterThan(zoomed.contentWidth, first.contentWidth)
        // Zoom re-places the runs but must not touch the captures again.
        XCTAssertEqual(cache.scans, 1)
        XCTAssertEqual(cache.placements, 2)

        let resized = cache.layout(moments: moments, viewportWidth: 1_600, density: 0.48)
        XCTAssertGreaterThanOrEqual(resized.contentWidth, zoomed.contentWidth)
        XCTAssertEqual(cache.scans, 1)

        var grown = moments
        grown.append(moment(id: "extra", at: 9_000_000, app: "Zed", bundle: "zed"))
        let extended = cache.layout(moments: grown, viewportWidth: 1_600, density: 0.48)
        XCTAssertEqual(extended.moments.count, grown.count)
        XCTAssertGreaterThan(extended.runs.count, resized.runs.count)
        XCTAssertEqual(cache.scans, 2, "new captures must invalidate the spine")
    }

    /// Re-placing a spine at a new width is the zoom path. It must land on the
    /// same layout as building from scratch, or zooming would drift.
    func testSpineReplacementMatchesAFullBuild() {
        let moments = clusteredShortSwitchesThenLongRun()
        let spine = TimelineSpine(moments: moments)
        let replaced = TimelineLayout(
            spine: spine,
            moments: moments,
            viewportWidth: 640,
            density: 0.9
        )
        let built = TimelineLayout(moments: moments, viewportWidth: 640, density: 0.9)
        XCTAssertEqual(replaced, built)
    }

    private func linearRun(containingMs ms: Int64, in runs: [AppUsageRun]) -> AppUsageRun? {
        guard let last = runs.last else { return nil }
        if let match = runs.dropLast().first(where: { $0.contains(ms: ms, isLast: false) }) {
            return match
        }
        if last.contains(ms: ms, isLast: true) || ms >= last.startMs { return last }
        return runs.first
    }

    private func linearRun(atX x: CGFloat, in runs: [AppUsageRun]) -> AppUsageRun? {
        guard let last = runs.last else { return nil }
        if let match = runs.dropLast().first(where: { $0.contains(x: x, isLast: false) }) {
            return match
        }
        if last.contains(x: x, isLast: true) || x >= last.startX { return last }
        return runs.first
    }

    private func linearResolveIndex(playheadMs: Int64, moments: [RecallMoment]) -> Int? {
        guard !moments.isEmpty else { return nil }
        if playheadMs < moments[0].capturedAtMs { return 0 }
        var resolved = 0
        for (index, moment) in moments.enumerated() {
            if moment.capturedAtMs <= playheadMs { resolved = index } else { break }
        }
        return resolved
    }

    private func evenlySpacedMoments(count: Int) -> [RecallMoment] {
        (0..<count).map { index in
            moment(
                id: "m\(index)",
                at: Int64(index) * 10_000,
                app: "Lody",
                bundle: "lody"
            )
        }
    }

    private func clusteredShortSwitchesThenLongRun() -> [RecallMoment] {
        var moments: [RecallMoment] = []
        for index in 0..<50 {
            moments.append(
                moment(
                    id: "short-\(index)",
                    at: Int64(index) * 1_000,
                    app: "App \(index)",
                    bundle: "app.\(index)"
                )
            )
        }
        moments.append(
            moment(id: "long", at: 50_000, app: "Xcode", bundle: "com.apple.dt.Xcode")
        )
        return moments
    }

    private func moment(
        id: String,
        at capturedAtMs: Int64,
        app: String,
        bundle: String
    ) -> RecallMoment {
        RecallMoment(
            id: id,
            sessionId: "s",
            capturedAtMs: capturedAtMs,
            imageArtifactId: "frame-\(id)",
            applicationName: app,
            bundleIdentifier: bundle
        )
    }
}
