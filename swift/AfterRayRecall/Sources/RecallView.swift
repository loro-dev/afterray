import AppKit
import QuartzCore
import SwiftUI

public typealias RecallImageLoader = (String) async throws -> Data
public typealias RecallArtifactLoader = (String) async throws -> Data
public typealias RecallOcrLoader = @Sendable (String) async throws -> OcrEvidence

public struct RecallView: View {
    public let moments: [RecallMoment]
    @Binding public var playheadMs: Int64
    @Binding public var isLive: Bool
    public let loadState: RecallLoadState
    public var tuning: RecallVisualTuning
    public let imageLoader: RecallImageLoader
    public var artifactLoader: RecallArtifactLoader?
    public var onToggleFavorite: (() -> Void)?
    public var onToggleAudio: ((RecallMoment) -> Void)?
    public var isAudioPlaying: Bool
    public var isAudioBuffering: Bool
    public var playingAudioArtifactID: String?
    public var onReload: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Capture state shown as a word next to the gear. Nil `onToggleRecording`
    /// hides the control entirely — the Visual Lab drives scenes without a daemon.
    public var recordingState: DaemonRecordingState?
    public var isChangingRecording: Bool
    public var onToggleRecording: (() -> Void)?
    public var chromeTopPadding: CGFloat
    public var trailingChromeInset: CGFloat
    public var daySummary: DaySummary
    /// Newest first; SwiftUI's LazyVStack only instantiates visible summary
    /// sections while the store pages older days from the daemon.
    public var summaryHistory: [DaySummary]
    public var summaryHistoryHasMore: Bool
    public var isLoadingSummaryHistory: Bool
    public var onLoadOlderSummaryHistory: (() -> Void)?
    /// Detach the history panel into a standalone window; nil hides the
    /// affordance (Visual Lab, snapshots).
    public var onPopOutHistory: (() -> Void)?
    public var onVisibleDayChange: ((Int64) -> Void)?
    /// Non-nil puts the view in search mode: the bottom bar becomes a filmstrip
    /// of matched frames and travel snaps between them instead of wall clock.
    public var searchSession: RecallSearchSession?
    public var thumbnailLoader: RecallThumbnailLoader?
    public var ocrLoader: RecallOcrLoader?
    public var onSelectSearchFrame: ((Int) -> Void)?

    @State private var dragOrigin: (playheadMs: Int64, isLive: Bool)?
    @State private var searchDragOrigin: Int?
    @State private var movementDirection = -1
    @State private var showsDetails = false
    @State private var detailsPage = RecallDetailsPage.root
    @State private var timelineViewportWidth: CGFloat = 720
    @State private var timelineZoom: CGFloat = 1
    @State private var isZoomingTimeline = false
    @State private var layoutCache = TimelineLayoutCache()
    /// True from the first scrub delta until the gesture (and its glide)
    /// settles. Prefetch and panel-follow both wait for the settle: doing
    /// either per frame at coast speed was the stutter being reported.
    @State private var isScrubbing = false
    /// Continuous travel stays inside this view. The store binding is committed
    /// once when motion settles, so the app root, history and audio pipeline do
    /// not republish at display-link frequency.
    @State private var scrubPlayheadMs: Int64?
    @State private var scrubIsLive: Bool?
    @State private var followPulse = 0
    @AppStorage(DaySummaryLayout.expandedStorageKey) private var daySummaryExpanded = true
    @State private var settledStill: SettledStill?
    @State private var searchScrollAccumulator: CGFloat = 0
    /// Trackpad travel needed to advance one filmstrip cell.
    private static let searchScrollPointsPerCell: CGFloat = 46
    @State private var highlightRegions: [OcrRegion] = []
    @State private var highlightMomentID: String?

    public init(
        moments: [RecallMoment],
        playheadMs: Binding<Int64>,
        isLive: Binding<Bool> = .constant(false),
        loadState: RecallLoadState = .ready,
        tuning: RecallVisualTuning = .standard,
        imageLoader: @escaping RecallImageLoader,
        artifactLoader: RecallArtifactLoader? = nil,
        onToggleFavorite: (() -> Void)? = nil,
        onToggleAudio: ((RecallMoment) -> Void)? = nil,
        isAudioPlaying: Bool = false,
        isAudioBuffering: Bool = false,
        playingAudioArtifactID: String? = nil,
        onReload: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        recordingState: DaemonRecordingState? = nil,
        isChangingRecording: Bool = false,
        onToggleRecording: (() -> Void)? = nil,
        chromeTopPadding: CGFloat = 22,
        trailingChromeInset: CGFloat = 0,
        daySummary: DaySummary = .empty,
        summaryHistory: [DaySummary] = [],
        summaryHistoryHasMore: Bool = false,
        isLoadingSummaryHistory: Bool = false,
        onLoadOlderSummaryHistory: (() -> Void)? = nil,
        onPopOutHistory: (() -> Void)? = nil,
        onVisibleDayChange: ((Int64) -> Void)? = nil,
        searchSession: RecallSearchSession? = nil,
        thumbnailLoader: RecallThumbnailLoader? = nil,
        ocrLoader: RecallOcrLoader? = nil,
        onSelectSearchFrame: ((Int) -> Void)? = nil
    ) {
        self.moments = moments
        self._playheadMs = playheadMs
        self._isLive = isLive
        self.loadState = loadState
        self.tuning = tuning
        self.imageLoader = imageLoader
        self.artifactLoader = artifactLoader
        self.onToggleFavorite = onToggleFavorite
        self.onToggleAudio = onToggleAudio
        self.isAudioPlaying = isAudioPlaying
        self.isAudioBuffering = isAudioBuffering
        self.playingAudioArtifactID = playingAudioArtifactID
        self.onReload = onReload
        self.onOpenSettings = onOpenSettings
        self.recordingState = recordingState
        self.isChangingRecording = isChangingRecording
        self.onToggleRecording = onToggleRecording
        self.chromeTopPadding = chromeTopPadding
        self.trailingChromeInset = trailingChromeInset
        self.daySummary = daySummary
        self.summaryHistory = summaryHistory
        self.summaryHistoryHasMore = summaryHistoryHasMore
        self.isLoadingSummaryHistory = isLoadingSummaryHistory
        self.onLoadOlderSummaryHistory = onLoadOlderSummaryHistory
        self.onPopOutHistory = onPopOutHistory
        self.onVisibleDayChange = onVisibleDayChange
        self.searchSession = searchSession
        self.thumbnailLoader = thumbnailLoader
        self.ocrLoader = ocrLoader
        self.onSelectSearchFrame = onSelectSearchFrame
    }

    private var selectedAudioIsActive: Bool {
        selectedMoment?.audioArtifactId != nil
            && selectedMoment?.audioArtifactId == playingAudioArtifactID
    }

    private var selectedMoment: RecallMoment? {
        RecallPlayhead.resolve(playheadMs: renderedPlayheadMs, moments: moments)
    }

    private var renderedPlayheadMs: Int64 {
        scrubPlayheadMs ?? playheadMs
    }

    private var renderedIsLive: Bool {
        scrubIsLive ?? isLive
    }

    private var displayedArtifactID: String? {
        guard let selectedMoment else { return nil }
        return RecallStillRequestPolicy.artifactID(
            for: selectedMoment,
            isMoving: isScrubbing
        )
    }

    /// Read on every scroll tick from three places — the drag handler, the
    /// playhead setter, and `body`. Building it there meant sorting and
    /// scanning every capture of the day three times a frame.
    private var timelineLayout: TimelineLayout {
        layoutCache.layout(
            moments: moments,
            viewportWidth: max(timelineViewportWidth, 1),
            density: tuning.timelineDensity * Double(timelineZoom)
        )
    }

    public var body: some View {
        ZStack {
            if !renderedIsLive {
                RecallPalette.background.ignoresSafeArea()
            }

            if !moments.isEmpty || renderedIsLive {
                recallContent
            } else if case .failed(let message) = loadState {
                FailureView(message: message, onReload: onReload)
            } else {
                EmptyRecallView(isProcessing: isProcessing)
                    .padding(40)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isProcessing: Bool {
        if case .processing = loadState { return true }
        return false
    }

    private var recallContent: some View {
        ZStack {
            if !renderedIsLive, let artifactID = displayedArtifactID {
                ImmersiveArtifactImage(
                    artifactID: artifactID,
                    loader: imageLoader,
                    animatesTransition: !isScrubbing,
                    onSettled: { settledStill = $0 }
                )
            }

            chromeGradients

            // Above the scrims: a dimmed highlight defeats the purpose.
            if !renderedIsLive, let still = settledStill, still.id == selectedMoment?.displayCacheKey {
                OcrHighlightOverlay(
                    regions: highlightRegions,
                    pixelSize: still.pixelSize,
                    blinkToken: still.id
                )
            }

            VStack(spacing: 0) {
                momentHeader
                    .frame(minHeight: RecallGeometry.overlayChromeButtonSize, alignment: .top)
                    .padding(.horizontal, RecallGeometry.overlayChromeMargin)
                    .padding(.top, chromeTopPadding)

                Spacer(minLength: 100)

                if daySummaryExpanded {
                    HStack(alignment: .bottom, spacing: 0) {
                        DaySummaryPanel(
                            onPopOut: onPopOutHistory.map { popOut in
                                {
                                    daySummaryExpanded = false
                                    popOut()
                                }
                            },
                            summaries: summaryHistory.isEmpty ? [daySummary] : summaryHistory,
                            playheadMs: playheadMs,
                            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
                            hasMore: summaryHistoryHasMore,
                            isLoadingMore: isLoadingSummaryHistory,
                            followPulse: followPulse,
                            onSelectSlot: { selectPlayhead(playheadMs: $0) },
                            onLoadMore: { onLoadOlderSummaryHistory?() }
                        )
                        // The panel owns every scroll that starts over it —
                        // vertical reads there must not scrub the timeline.
                        .background(ScrollFenceView())
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, RecallGeometry.overlayChromeMargin)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Last thing above the timeline chrome, so the line you heard
                // stays next to the moment it was heard at. Above the summary
                // panel it drifted to the top of the screen whenever the panel
                // was open, which is where a caption reads as unrelated.
                if !renderedIsLive, selectedMoment?.hasVisibleTranscript == true {
                    TranscriptCaption(
                        text: selectedMoment?.transcriptText,
                        canPlay: selectedMoment?.audioArtifactId != nil,
                        isPlaying: isAudioPlaying && selectedAudioIsActive,
                        isBuffering: isAudioBuffering && selectedAudioIsActive,
                        onToggleAudio: {
                            if let moment = selectedMoment {
                                onToggleAudio?(moment)
                            }
                        }
                    )
                    .padding(.horizontal, RecallGeometry.overlayChromeMargin)
                    .padding(.bottom, 12)
                }

                timelineChromeRow
                    .padding(.bottom, 9)

                if let searchSession, let thumbnailLoader {
                    SearchFilmstrip(
                        session: searchSession,
                        tuning: tuning,
                        selectedDate: selectedDate,
                        isScrubbing: isScrubbing,
                        thumbnailLoader: thumbnailLoader,
                        onSelectIndex: { onSelectSearchFrame?($0) },
                        onViewportWidthChange: { timelineViewportWidth = $0 }
                    )
                    .padding(.bottom, 18)
                } else {
                    AppUsageTimeline(
                        layout: timelineLayout,
                        playheadMs: renderedPlayheadMs,
                        isLive: renderedIsLive,
                        selectedMoment: selectedMoment,
                        tuning: tuning,
                        zoom: $timelineZoom,
                        isZooming: $isZoomingTimeline,
                        onSelectMs: { selectPlayhead(playheadMs: $0) },
                        onViewportWidthChange: { timelineViewportWidth = $0 }
                    )
                    .padding(.bottom, 18)
                }
            }

            if showsDetails, !renderedIsLive, let moment = selectedMoment {
                HStack {
                    Spacer(minLength: 0)
                    RecallDetailsMenu(
                        moment: moment,
                        page: $detailsPage,
                        isProcessing: isProcessing,
                        artifactLoader: artifactLoader,
                        onToggleAudio: onToggleAudio,
                        isAudioPlaying: isAudioPlaying,
                        isAudioBuffering: isAudioBuffering,
                        playingAudioArtifactID: playingAudioArtifactID,
                        onClose: { showsDetails = false }
                    )
                }
                .padding(.top, RecallGeometry.detailsMenuTopPadding(chromeTopPadding: chromeTopPadding))
                .padding(.trailing, RecallGeometry.overlayChromeMargin)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }

            ScrollWheelMonitor(onScroll: handleScroll)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(recallDrag)
        .onChange(of: isZoomingTimeline) { _, zooming in
            if zooming {
                dragOrigin = nil
                finishScrubbing()
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
        .onKeyPress(.space) {
            guard !renderedIsLive, let moment = selectedMoment, moment.hasVisibleTranscript, moment.audioArtifactId != nil else {
                return .ignored
            }
            onToggleAudio?(moment)
            return .handled
        }
        .animation(.easeOut(duration: 0.18), value: showsDetails)
        .animation(.easeOut(duration: 0.18), value: daySummaryExpanded)
        .task(id: "\(selectedMoment?.id ?? "-"):\(movementDirection):\(isScrubbing)") {
            // While the scrub coasts, the selected moment changes every
            // frame; forty-artifact prefetch batches at that rate were pure
            // main-thread churn. The visible still keeps updating through
            // its own throttle; neighbours warm once motion settles.
            guard !isScrubbing else { return }
            // Give the newly requested exact Nth frame first access to the
            // daemon and VideoToolbox before low-priority poster warming.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !isScrubbing else { return }
            prefetchAroundSelection()
        }
        // Waits for the settle like the prefetch above. Search results hop
        // between days, so a single flick used to ask the daemon for a day
        // summary — and the history pages behind it — once per cell, each
        // answer rebuilding the whole summary document mid-scrub.
        .task(id: "\(playheadDayKey):\(isScrubbing)") {
            guard !isScrubbing else { return }
            onVisibleDayChange?(renderedPlayheadMs)
        }
        .task(id: "\(highlightKey):\(isScrubbing)") {
            await loadHighlightRegions()
        }
        .task(id: "\(searchSession?.selectedIndex ?? -1):\(isScrubbing)") {
            guard !isScrubbing else { return }
            prefetchFilmstripThumbnails()
        }
    }

    private var playheadDayKey: String {
        DaySummaryLayout.localDayKey(ms: renderedPlayheadMs)
    }

    /// Reloading is only worth it when the frame or the query actually changed.
    private var highlightKey: String {
        "\(selectedMoment?.id ?? "-")|\(searchSession?.query ?? "")"
    }

    private var selectedDate: Date {
        let ms = selectedMoment?.capturedAtMs ?? renderedPlayheadMs
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }

    /// Fetches OCR boxes for the selected frame and keeps only those the query
    /// actually hit. Cleared eagerly so a stale highlight never sits over a new
    /// frame while the fetch is in flight.
    private func loadHighlightRegions() async {
        highlightRegions = []
        // One evidence round trip per cell the scrub passes through is a queue
        // of requests for frames nobody is looking at any more. The boxes are
        // only worth fetching for the frame the scrub stops on.
        guard !isScrubbing else { return }
        guard
            let ocrLoader,
            let moment = selectedMoment,
            let query = searchSession?.query,
            !query.isEmpty
        else {
            highlightMomentID = nil
            return
        }
        highlightMomentID = moment.id
        guard let evidence = try? await ocrLoader(moment.id) else { return }
        // The selection may have moved on while this was in flight.
        guard highlightMomentID == moment.id else { return }
        highlightRegions = OcrHighlight.matching(regions: evidence.regions, query: query)
    }

    private func prefetchFilmstripThumbnails() {
        guard let searchSession, let thumbnailLoader else { return }
        let center = searchSession.selectedIndex
        let ids = (-8...8).compactMap { offset -> String? in
            let index = center + offset
            guard searchSession.frames.indices.contains(index) else { return nil }
            return searchSession.frames[index].momentId
        }
        RecallThumbnailCache.shared.prefetch(momentIDs: ids, loader: thumbnailLoader)
    }

    /// The bottom scrim is unconditional: live or not, the timeline and the
    /// controls beside it sit over whatever is on screen, and a busy desktop
    /// leaves them unreadable without it. The top and side washes are for the
    /// recalled still only — in live view they would dim the real desktop.
    private var chromeGradients: some View {
        ZStack {
            if !renderedIsLive {
                LinearGradient(
                    colors: [.black.opacity(tuning.topScrimOpacity), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.23)
                )
                LinearGradient(
                    colors: [.black.opacity(0.17), .clear, .black.opacity(0.11)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.52),
                    .init(color: .black.opacity(0.18), location: 0.72),
                    .init(color: .black.opacity(tuning.bottomScrimOpacity), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// The top-right cluster. Settings lives here rather than beside the
    /// timeline: down there it sat in the busiest corner of the overlay and
    /// read as another playback control. The identity capsule and the context
    /// button belong to a recalled frame, so they drop away in live view —
    /// the gear does not, and stays reachable either way.
    private var momentHeader: some View {
        // Top-aligned: the identity capsule grows downward when it carries a
        // window title, and the chrome cluster must not grow with it.
        HStack(alignment: .top, spacing: RecallGeometry.overlayChromeItemGap) {
            if !renderedIsLive {
                AppIdentity(moment: selectedMoment)
            }

            Spacer(minLength: 24)

            if isProcessing, !renderedIsLive {
                Label("Understanding", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 12)
                    .frame(height: RecallGeometry.overlayChromeButtonSize)
                    .recallGlass(in: .capsule)
            }

            RecallGlassCluster {
                HStack(spacing: RecallGeometry.overlayChromeItemGap) {
                    if !renderedIsLive {
                        RecallChromeIconButton(
                            symbol: showsDetails ? "sidebar.right" : "info.circle",
                            help: showsDetails ? "Hide captured context" : "Show captured context",
                            action: {
                                if showsDetails {
                                    showsDetails = false
                                } else {
                                    detailsPage = .root
                                    showsDetails = true
                                }
                            }
                        )
                    }

                    if let onOpenSettings {
                        RecallChromeIconButton(
                            symbol: "gearshape",
                            help: "Settings",
                            action: onOpenSettings
                        )
                    }
                }
            }
        }
    }

    /// The day-summary toggle sits directly under the panel it opens and
    /// directly above the timeline it belongs to — the control is within
    /// reach of what it reveals. Settings used to share this cluster; it is
    /// a whole-app control, not a playback one, so it moved to the top right.
    private var daySummaryChrome: some View {
        RecallGlassCluster {
            RecallChromeIconButton(
                symbol: daySummaryExpanded
                    ? "rectangle.bottomhalf.inset.filled"
                    : "list.bullet.rectangle",
                help: daySummaryExpanded ? "Hide today's summary" : "Show today's summary",
                tint: daySummaryExpanded ? RecallPalette.ray : .white,
                action: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        daySummaryExpanded.toggle()
                    }
                }
            )
        }
    }

    /// One row directly above the timeline: capture state, then the controls,
    /// then zoom — all left-aligned over the bottom scrim, which is the only
    /// part of the frame guaranteed to be dark enough to read them against.
    /// The playhead clock rides the same row but stays centred on screen.
    private var timelineChromeRow: some View {
        ZStack {
            HStack(spacing: RecallGeometry.overlayChromeItemGap) {
                if let onToggleRecording {
                    TimelineRecordingStatusButton(
                        state: recordingState,
                        isChanging: isChangingRecording,
                        action: onToggleRecording
                    )
                }

                daySummaryChrome

                TimelineZoomStrip(zoom: $timelineZoom, isDragging: $isZoomingTimeline)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, RecallGeometry.overlayChromeMargin)

            PlayheadTimestamp(date: selectedDate, isLive: renderedIsLive)
        }
    }

    private var recallDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if isZoomingTimeline {
                    dragOrigin = nil
                    searchDragOrigin = nil
                    return
                }
                if let searchSession {
                    beginScrubbing(holdsPlayhead: false)
                    // Search results are discrete, so a drag walks whole cells
                    // rather than scrubbing continuously through time.
                    let origin = searchDragOrigin ?? searchSession.selectedIndex
                    searchDragOrigin = origin
                    let layout = SearchFilmstripLayout(
                        count: searchSession.frames.count,
                        viewportWidth: timelineViewportWidth
                    )
                    let steps = layout.steps(forDragTranslation: value.translation.width)
                    selectSearchIndex(origin + steps)
                    return
                }
                if dragOrigin == nil {
                    beginScrubbing()
                    dragOrigin = (renderedPlayheadMs, renderedIsLive)
                }
                guard let origin = dragOrigin else { return }
                let scale = 54 / max(tuning.dragPointsPerMoment, 1)
                let moved = RecallPlayhead.move(
                    playheadMs: origin.playheadMs,
                    isLive: origin.isLive,
                    deltaX: value.translation.width * scale,
                    layout: timelineLayout
                )
                selectTransientPlayhead(playheadMs: moved.playheadMs, isLive: moved.isLive)
            }
            .onEnded { _ in
                dragOrigin = nil
                searchDragOrigin = nil
                finishScrubbing()
            }
    }

    /// Clamps and forwards; the owner decides what selecting a frame means.
    private func selectSearchIndex(_ index: Int) {
        guard let searchSession, !searchSession.frames.isEmpty else { return }
        let clamped = min(max(index, 0), searchSession.frames.count - 1)
        guard clamped != searchSession.selectedIndex else { return }
        onSelectSearchFrame?(clamped)
    }

    private func handleScroll(delta: CGFloat, isPrecise: Bool, ended: Bool) {
        if ended {
            searchScrollAccumulator = 0
            finishScrubbing()
            return
        }
        if let searchSession {
            beginScrubbing(holdsPlayhead: false)
            guard delta != 0 else { return }
            // Same sign as the timeline: a positive delta pushes the content
            // right and travels backward in time, which on the strip means the
            // older results left of the playhead.
            if !isPrecise {
                selectSearchIndex(searchSession.selectedIndex + (delta > 0 ? 1 : -1))
                return
            }
            // A trackpad emits dozens of small deltas per flick. Accumulating
            // to a whole cell keeps one swipe from blowing through the results.
            searchScrollAccumulator += delta
            let steps = Int(searchScrollAccumulator / Self.searchScrollPointsPerCell)
            guard steps != 0 else { return }
            searchScrollAccumulator -= CGFloat(steps) * Self.searchScrollPointsPerCell
            selectSearchIndex(searchSession.selectedIndex + steps)
            return
        }
        beginScrubbing()
        guard delta != 0, !moments.isEmpty else { return }
        if !isPrecise {
            let stepped = RecallPlayhead.stepMoment(
                playheadMs: renderedPlayheadMs,
                isLive: renderedIsLive,
                delta: delta > 0 ? -1 : 1,
                moments: moments
            )
            selectTransientPlayhead(playheadMs: stepped.playheadMs, isLive: stepped.isLive)
            return
        }

        let moved = RecallPlayhead.move(
            playheadMs: renderedPlayheadMs,
            isLive: renderedIsLive,
            deltaX: delta,
            layout: timelineLayout
        )
        selectTransientPlayhead(playheadMs: moved.playheadMs, isLive: moved.isLive)
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: moveSelection(by: -1)
        case .right: moveSelection(by: 1)
        default: break
        }
    }

    private func moveSelection(by delta: Int) {
        if let searchSession {
            // Arrow keys walk the strip, not the ranking: left is older, which
            // is the higher index in a newest-first result set.
            selectSearchIndex(searchSession.selectedIndex - delta)
            return
        }
        let stepped = RecallPlayhead.stepMoment(
            playheadMs: playheadMs,
            isLive: isLive,
            delta: delta,
            moments: moments
        )
        selectPlayhead(playheadMs: stepped.playheadMs, isLive: stepped.isLive)
    }

    private func selectPlayhead(playheadMs nextMs: Int64, isLive nextLive: Bool? = nil) {
        guard !moments.isEmpty else { return }
        let layout = timelineLayout
        let resolvedLive = nextLive ?? (nextMs >= layout.endMs)
        let clampedMs = resolvedLive
            ? (moments.last?.capturedAtMs ?? nextMs)
            : layout.clamp(nextMs)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if clampedMs != playheadMs {
                movementDirection = clampedMs > playheadMs ? 1 : -1
            }
            playheadMs = clampedMs
            isLive = resolvedLive
        }
    }

    private func beginScrubbing(holdsPlayhead: Bool = true) {
        guard !isScrubbing else { return }
        if holdsPlayhead {
            scrubPlayheadMs = playheadMs
            scrubIsLive = isLive
        }
        isScrubbing = true
        RecallDecodedImageCache.shared.prioritizeScrubPreviews()
    }

    private func selectTransientPlayhead(playheadMs nextMs: Int64, isLive nextLive: Bool) {
        guard !moments.isEmpty else { return }
        let layout = timelineLayout
        let clampedMs = nextLive
            ? (moments.last?.capturedAtMs ?? nextMs)
            : layout.clamp(nextMs)
        if clampedMs != renderedPlayheadMs {
            movementDirection = clampedMs > renderedPlayheadMs ? 1 : -1
        }
        scrubPlayheadMs = clampedMs
        scrubIsLive = nextLive
    }

    private func finishScrubbing() {
        guard isScrubbing else { return }
        let settledMs = renderedPlayheadMs
        let settledIsLive = renderedIsLive
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            playheadMs = settledMs
            isLive = settledIsLive
            scrubPlayheadMs = nil
            scrubIsLive = nil
            isScrubbing = false
            followPulse += 1
        }
    }

    private func prefetchAroundSelection() {
        guard !moments.isEmpty else { return }
        let center = RecallPlayhead.resolveIndex(playheadMs: renderedPlayheadMs, moments: moments)
            ?? moments.count - 1
        var offsets = [0]
        for distance in 1...8 {
            offsets.append(distance * movementDirection)
            offsets.append(-distance * movementDirection)
        }
        let artifactIDs = offsets.compactMap { offset -> String? in
            let index = center + offset
            return moments.indices.contains(index) ? moments[index].previewCacheKey : nil
        }
        var seen = Set<String>()
        let uniqueArtifactIDs = artifactIDs.filter { seen.insert($0).inserted }
        RecallDecodedImageCache.shared.prefetch(
            artifactIDs: uniqueArtifactIDs,
            loader: imageLoader
        )
    }
}

/// A still that has finished fading in and now owns the screen at full opacity.
struct SettledStill: Equatable {
    let id: String
    let pixelSize: CGSize
}

private struct ImmersiveArtifactImage: View {
    let artifactID: String
    let loader: RecallImageLoader
    let animatesTransition: Bool
    var onSettled: ((SettledStill) -> Void)?
    @StateObject private var player = RecallStillPlayer()

    var body: some View {
        ZStack {
            // Two host views only. SwiftUI never feeds them frames — the player
            // owns pixels and opacity so a visible layer cannot be retargeted.
            ArtifactYUVView(
                bindsOpacity: false,
                attachment: player.slotA
            )
            .id("recall-slot-a")
            .zIndex(player.overlaySlotIsA ? 1 : 0)
            ArtifactYUVView(
                bindsOpacity: false,
                attachment: player.slotB
            )
            .id("recall-slot-b")
            .zIndex(player.overlaySlotIsA ? 0 : 1)
            if !player.hasVisibleStill {
                ProgressView().controlSize(.small).tint(.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear {
            player.updateLoader(loader)
            player.request(artifactID, animated: animatesTransition)
        }
        .onChange(of: artifactID) { _, newID in
            player.request(newID, animated: animatesTransition)
        }
        .onChange(of: player.settled) { _, settled in
            if let settled { onSettled?(settled) }
        }
        .onDisappear {
            player.invalidate()
        }
    }
}

private struct PresentedStill: Equatable {
    let id: String
    let frame: RecallDisplayFrame

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.frame === rhs.frame
    }
}

/// Exactly two layers. A slot's frame is only replaced while its opacity is 0.
/// When the incoming slot reaches 100% it becomes the base; the old base is
/// hidden and cleared. Visible requests consume the same bounded decoded-frame
/// cache warmed after settle, instead of paying a second VideoToolbox decode.
@MainActor
private final class RecallStillPlayer: ObservableObject {
    let slotA = ArtifactViewAttachment()
    let slotB = ArtifactViewAttachment()
    @Published private(set) var hasVisibleStill = false
    /// Incoming slot is always drawn above the base so a ping-pong fade
    /// is never hidden under the previous still.
    @Published private(set) var overlaySlotIsA = false
    /// The still currently at full opacity. Publishing this is what lets the
    /// OCR highlight wait for the fade instead of flashing mid-crossfade.
    @Published private(set) var settled: SettledStill?

    private enum Slot {
        case a, b

        var other: Slot { self == .a ? .b : .a }
    }

    private var gate = RecallStillGate()
    private var loader: RecallImageLoader?
    private var loadTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var fadeGeneration: UInt64 = 0
    private var isAnimating = false
    private var animatesRequest: [String: Bool] = [:]
    private var baseSlot: Slot = .a
    private var incomingSlot: Slot { baseSlot.other }

    func updateLoader(_ loader: @escaping RecallImageLoader) {
        self.loader = loader
    }

    func request(_ artifactID: String, animated: Bool) {
        animatesRequest[artifactID] = animated
        handle(gate.request(artifactID))
    }

    func invalidate() {
        loadTask?.cancel()
        transitionTask?.cancel()
        fadeGeneration &+= 1
        isAnimating = false
        animatesRequest.removeAll()
    }

    private func handle(_ step: RecallStillGate.Step) {
        switch step {
        case .none:
            return
        case .needFrame(let id):
            acquire(id)
        }
    }

    private func acquire(_ id: String) {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let frame = await self.loadFresh(id)
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            if let frame {
                self.consumeReady(id, frame: frame)
            } else {
                self.animatesRequest[id] = nil
                self.handle(self.gate.loadFailed(id))
            }
        }
    }

    private func loadFresh(_ id: String) async -> RecallDisplayFrame? {
        guard let loader else { return nil }
        return await RecallDecodedImageCache.shared.frame(
            artifactID: id,
            loader: loader,
            priority: .userInitiated
        )
    }

    private func consumeReady(_ id: String, frame: RecallDisplayFrame) {
        let animated = animatesRequest.removeValue(forKey: id) ?? true
        switch gate.frameReady(id) {
        case .ignore:
            return
        case .settle:
            Task { [weak self] in
                guard let self else { return }
                await self.waitForViews()
                self.installBase(PresentedStill(id: id, frame: frame))
                self.handle(self.gate.commitSettle(id))
            }
        case .transition:
            startIncomingFade(
                PresentedStill(id: id, frame: frame),
                animated: animated
            )
        }
    }

    /// Called once the incoming slot has reached full opacity.
    private func markSettled(_ still: PresentedStill) {
        settled = SettledStill(id: still.id, pixelSize: still.frame.pixelSize)
    }

    private func waitForViews() async {
        for _ in 0..<40 {
            if slotA.view != nil, slotB.view != nil { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    private func installBase(_ still: PresentedStill) {
        fadeGeneration &+= 1
        isAnimating = false
        overlaySlotIsA = incomingSlot == .a
        view(incomingSlot)?.clearDisplayedContent()
        let base = view(baseSlot)
        base?.display(still.frame)
        base?.setContentOpacity(1)
        hasVisibleStill = true
        settled = SettledStill(id: still.id, pixelSize: still.frame.pixelSize)
    }

    private func startIncomingFade(_ still: PresentedStill, animated: Bool) {
        guard !isAnimating else { return }
        isAnimating = true
        fadeGeneration &+= 1
        let generation = fadeGeneration
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForViews()
            guard self.isCurrentFade(generation) else { return }
            let incoming = self.view(self.incomingSlot)
            incoming?.setContentOpacity(0)
            incoming?.display(still.frame)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(8))
            guard self.isCurrentFade(generation) else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !animated
                ? 0
                : RecallStillGate.animationDuration
            incoming?.animateContentOpacity(
                to: 1,
                duration: duration,
                timingFunction: CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.85,
                    0.87,
                    0.22
                )
            )
            if duration > 0 {
                try? await Task.sleep(for: RecallStillGate.interval)
            }
            guard self.isCurrentFade(generation) else { return }
            self.promoteIncomingToBase()
            self.isAnimating = false
            self.markSettled(still)
            self.handle(self.gate.transitionFinished())
        }
    }

    private func promoteIncomingToBase() {
        let outgoing = view(baseSlot)
        outgoing?.setContentOpacity(0)
        outgoing?.clearDisplayedContent()
        baseSlot = incomingSlot
        overlaySlotIsA = incomingSlot == .a
        hasVisibleStill = true
    }

    private func view(_ slot: Slot) -> ArtifactLayerView? {
        switch slot {
        case .a: slotA.view
        case .b: slotB.view
        }
    }

    private func isCurrentFade(_ generation: UInt64) -> Bool {
        !Task.isCancelled && fadeGeneration == generation && isAnimating
    }
}

@MainActor
private final class RecallDecodedImageCache {
    static let shared = RecallDecodedImageCache()

    private let frames = NSCache<NSString, RecallDisplayFrame>()
    private var inFlight: [String: InFlight] = [:]
    private var pendingPrefetches: [PrefetchRequest] = []
    private var activePrefetches = 0
    private let maximumConcurrentPrefetches = 1
    private var generation: UInt64 = 0
    private var nextInFlightToken: UInt64 = 0

    private init() {
        frames.countLimit = 20
        frames.totalCostLimit = 384 * 1_024 * 1_024
    }

    func cached(artifactID: String) -> RecallDisplayFrame? {
        frames.object(forKey: artifactID as NSString)
    }

    func frame(
        artifactID: String,
        loader: @escaping RecallImageLoader,
        priority: TaskPriority = .utility
    ) async -> RecallDisplayFrame? {
        if let cached = cached(artifactID: artifactID) { return cached }
        if let existing = inFlight[artifactID] { return await existing.task.value }

        let requestGeneration = generation
        nextInFlightToken &+= 1
        let token = nextInFlightToken
        let task = Task { @MainActor () -> RecallDisplayFrame? in
            guard let data = try? await loader(artifactID) else { return nil }
            guard !Task.isCancelled else { return nil }
            let decoded = await Task.detached(priority: priority) {
                RecallFrameDecoder.decode(data)
            }.value
            return Task.isCancelled ? nil : decoded
        }
        inFlight[artifactID] = InFlight(token: token, task: task)
        let decoded = await task.value
        guard inFlight[artifactID]?.token == token else { return decoded }
        inFlight[artifactID] = nil
        guard generation == requestGeneration else { return decoded }
        if let decoded {
            frames.setObject(decoded, forKey: artifactID as NSString, cost: decoded.cost)
        }
        return decoded
    }

    func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        pendingPrefetches.removeAll()
        frames.removeAllObjects()
    }

    /// Drop queued neighbours and exact GOP loads as soon as the finger moves.
    /// Raw daemon reads may still finish into their encrypted-data cache, but a
    /// cancelled exact request is checked before it can occupy VideoToolbox.
    func prioritizeScrubPreviews() {
        pendingPrefetches.removeAll()
        let exactGopIDs = inFlight.keys.filter { $0.hasPrefix("gop:") }
        for artifactID in exactGopIDs {
            inFlight[artifactID]?.task.cancel()
            inFlight[artifactID] = nil
        }
    }

    func prefetch(
        artifactIDs: [String],
        loader: @escaping RecallImageLoader
    ) {
        pendingPrefetches = artifactIDs.compactMap { artifactID in
            guard
                cached(artifactID: artifactID) == nil,
                inFlight[artifactID] == nil
            else { return nil }
            return PrefetchRequest(artifactID: artifactID, loader: loader)
        }
        pumpPrefetches()
    }

    private func pumpPrefetches() {
        while activePrefetches < maximumConcurrentPrefetches, !pendingPrefetches.isEmpty {
            let request = pendingPrefetches.removeFirst()
            guard
                cached(artifactID: request.artifactID) == nil,
                inFlight[request.artifactID] == nil
            else { continue }
            activePrefetches += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await frame(
                    artifactID: request.artifactID,
                    loader: request.loader,
                    priority: .utility
                )
                activePrefetches -= 1
                pumpPrefetches()
            }
        }
    }

    private struct PrefetchRequest {
        let artifactID: String
        let loader: RecallImageLoader
    }

    private struct InFlight {
        let token: UInt64
        let task: Task<RecallDisplayFrame?, Never>
    }
}

@MainActor
public func clearRecallDecodedImageCache() {
    RecallDecodedImageCache.shared.clearSensitiveData()
}

private struct AppIdentity: View {
    let moment: RecallMoment?

    /// The app name alone rarely identifies a frame — a day in one editor is a
    /// dozen different files. The window title is what tells them apart.
    private var windowTitle: String? {
        guard
            let title = moment?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { return nil }
        return title
    }

    var body: some View {
        HStack(spacing: 9) {
            ApplicationIcon(bundleIdentifier: moment?.bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(moment?.applicationName ?? "Idle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let windowTitle {
                    Text(windowTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: RecallGeometry.appIdentityTitleMaxWidth, alignment: .leading)
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .padding(.vertical, windowTitle == nil ? 0 : 6)
        .frame(minHeight: RecallGeometry.overlayChromeButtonSize)
        .recallGlass(in: .capsule)
    }
}

private struct AppUsageTimeline: View {
    let layout: TimelineLayout
    let playheadMs: Int64
    let isLive: Bool
    let selectedMoment: RecallMoment?
    let tuning: RecallVisualTuning
    @Binding var zoom: CGFloat
    @Binding var isZooming: Bool
    let onSelectMs: (Int64) -> Void
    let onViewportWidthChange: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let selectedX = layout.playheadX(playheadMs: playheadMs, isLive: isLive)

                ZStack(alignment: .leading) {
                    Color.black.opacity(0.001)
                    timelineTrack(visible: Self.visibleRange(centeredOn: selectedX, width: width))
                        .offset(x: width / 2 - selectedX)

                    Rectangle()
                        .fill(RecallPalette.ray)
                        .frame(width: 2, height: tuning.timelineSegmentHeight + 10)
                        .position(x: width / 2, y: (tuning.timelineSegmentHeight + 20) / 2)
                        .shadow(color: RecallPalette.ray.opacity(0.9), radius: 7)
                }
                .contentShape(Rectangle())
                .clipped()
                .onAppear { onViewportWidthChange(width) }
                .onChange(of: width) { _, newWidth in
                    onViewportWidthChange(newWidth)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: tuning.timelineSegmentHeight + 20)
            .contentShape(Rectangle())
            .allowsHitTesting(!isZooming)

            HStack(spacing: 7) {
                Image(systemName: "arrow.left.and.right")
                Text("Drag to zoom · Swipe to travel · Esc to close")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var selectedDate: Date {
        let ms = selectedMoment?.capturedAtMs ?? playheadMs
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }

    /// The track is as wide as the whole archive — tens of thousands of points
    /// — while the viewport shows one screen of it. Everything outside
    /// `visible` used to be built, laid out, gradient-filled and given a
    /// tooltip on every frame, only to be clipped away.
    ///
    /// Runs are placed by their own `startX` rather than stacked, so skipping
    /// one costs nothing: an `HStack` would have to lay out the segments it
    /// never draws just to know where the next one goes.
    private func timelineTrack(visible: ClosedRange<CGFloat>) -> some View {
        let visibleRuns = layout.runs(intersecting: visible)
        let lastIndex = layout.runs.count - 1
        return ZStack(alignment: .leading) {
            Color.black.opacity(0.001)
                .frame(width: layout.contentWidth, height: tuning.timelineSegmentHeight)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        onSelectMs(layout.snapToRecordedMs(layout.ms(x: value.location.x)))
                    }
                )

            ForEach(Array(visibleRuns.indices), id: \.self) { index in
                let run = layout.runs[index]
                let drawnWidth = max(
                    run.width - (index == lastIndex ? 0 : tuning.timelineSegmentGap),
                    1
                )
                let height = run.isIdle ? 7 : tuning.timelineSegmentHeight
                AppUsageSegmentView(run: run, width: drawnWidth, height: height)
                    .frame(width: drawnWidth, height: height)
                    .position(x: run.startX + run.width / 2, y: 28)
                    .help(
                        run.isIdle
                            ? "这段时间没有录制 · \(DurationFormatter.short(milliseconds: run.durationMs))"
                            : "\(run.applicationName) · \(DurationFormatter.short(milliseconds: run.durationMs))"
                    )
            }

            ForEach(layout.favorites.filter { visible.contains($0.x) }) { favorite in
                Image(systemName: "star.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .position(x: favorite.x, y: 2)
            }
        }
        .frame(width: layout.contentWidth, height: 56)
        .padding(.vertical, 6)
    }

    /// One viewport either side of the playhead, plus a margin so a segment
    /// straddling an edge is drawn whole rather than appearing mid-scroll.
    private static func visibleRange(centeredOn x: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let reach = width / 2 + 96
        return (x - reach)...(x + reach)
    }
}

/// Draws the matched OCR boxes over the still, pulses them, then leaves them up.
///
/// Mounted only once the crossfade has settled — a box drawn over a
/// half-faded frame points at the wrong pixels.
private struct OcrHighlightOverlay: View {
    let regions: [OcrRegion]
    let pixelSize: CGSize
    /// Changing this restarts the pulse: a new frame deserves a new flash.
    let blinkToken: String

    private static let pulses = 3
    private static let pulseDuration = 0.22
    /// After the pulses the boxes stay up. They are the answer to the query,
    /// not a transient notification.
    private static let restingOpacity: Double = 0.9

    @State private var opacity: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let content = OcrHighlight.contentRect(
                pixelSize: pixelSize,
                viewSize: geometry.size
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                    let box = OcrHighlight.rect(for: region, in: content)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(RecallPalette.ray.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(RecallPalette.ray, lineWidth: 1.5)
                        }
                        .shadow(color: RecallPalette.ray.opacity(0.7), radius: 6)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .task(id: blinkToken) { await pulse() }
    }

    private func pulse() async {
        guard !regions.isEmpty else {
            opacity = 0
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            opacity = Self.restingOpacity
            return
        }
        for _ in 0..<Self.pulses {
            withAnimation(.easeOut(duration: Self.pulseDuration)) { opacity = 1 }
            try? await Task.sleep(for: .seconds(Self.pulseDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: Self.pulseDuration)) { opacity = 0.25 }
            try? await Task.sleep(for: .seconds(Self.pulseDuration))
            guard !Task.isCancelled else { return }
        }
        withAnimation(.easeOut(duration: Self.pulseDuration)) {
            opacity = Self.restingOpacity
        }
    }
}

/// The absolute time under the playhead. Shared by the app timeline and the
/// search filmstrip: whatever the strip below is showing, this stays the one
/// place that spells out *when*.
struct PlayheadTimestamp: View {
    let date: Date
    let isLive: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(isLive ? "NOW" : date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                // Explicit, not `.primary`: this always sits on dark chrome, and
                // relying on the inherited scheme renders it black-on-black in
                // any host that does not carry the dark appearance through.
                .foregroundStyle(RecallPalette.textPrimary)
            Text(
                isLive
                    ? "Swipe right to enter history"
                    : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            )
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .recallGlass(in: .capsule)
        .overlay(alignment: .bottom) {
            Circle()
                .fill(RecallPalette.ray)
                .frame(width: 5, height: 5)
                .offset(y: 11)
                .shadow(color: RecallPalette.ray, radius: 6)
        }
    }
}

/// Capture state as a word, not a symbol. "Recording" / "Waiting" / "Paused"
/// is wordier than a dot, but a dot alone cannot say which of the three it is,
/// and the row has room to spare. Tapping toggles capture.
private struct TimelineRecordingStatusButton: View {
    let state: DaemonRecordingState?
    let isChanging: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: effectiveState == .recording ? indicatorColor.opacity(0.8) : .clear,
                        radius: 5
                    )
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 12)
            .frame(height: RecallGeometry.overlayChromeButtonSize)
            .contentShape(Capsule())
        }
        .buttonStyle(RecallGlassPressStyle())
        .recallGlass(in: .capsule)
        .disabled(effectiveState == .stopping || isChanging)
        .help(toggleHelp)
        .accessibilityLabel("Capture status")
        .accessibilityValue(statusLabel)
        .accessibilityHint(toggleHelp)
    }

    /// A toggle in flight reads as "Waiting" rather than briefly flashing back
    /// to the state it is leaving.
    private var effectiveState: DaemonRecordingState? {
        if isChanging, state == nil || state == .idle {
            return .waiting
        }
        return state
    }

    private var statusLabel: String {
        switch effectiveState {
        case .idle: "Paused"
        case .waiting: "Waiting"
        case .recording: "Recording"
        case .stopping: "Pausing"
        case .failed: "Failed"
        case nil: "Offline"
        }
    }

    private var indicatorColor: Color {
        switch effectiveState {
        case .recording: .red
        case .waiting, .stopping: .orange
        case .failed: .red.opacity(0.8)
        case .idle: .white.opacity(0.48)
        case nil: .secondary.opacity(0.55)
        }
    }

    private var toggleHelp: String {
        switch effectiveState {
        case .waiting, .recording, .stopping: "Pause capture"
        case .idle, .failed, nil: "Resume capture"
        }
    }
}

private struct TimelineZoomStrip: View {
    @Binding var zoom: CGFloat
    @Binding var isDragging: Bool
    @State private var dragOrigin: CGFloat?

    private static let range: ClosedRange<CGFloat> = 0.4...5
    private static let trackWidth: CGFloat = 148

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .onTapGesture { step(0.8) }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: Self.trackWidth, height: 5)
                Capsule()
                    .fill(RecallPalette.ray.opacity(0.85))
                    .frame(width: max(thumbX, 6), height: 5)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: thumbX - 5.5)
            }
            .frame(width: Self.trackWidth, height: 18)
            .contentShape(Rectangle())

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .onTapGesture { step(1.25) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .recallGlass(in: .capsule)
        .help("Drag left to zoom out, right to zoom in")
        .highPriorityGesture(drag)
    }

    private var thumbX: CGFloat {
        let lower = log(Self.range.lowerBound)
        let span = log(Self.range.upperBound) - lower
        let t = (log(min(max(zoom, Self.range.lowerBound), Self.range.upperBound)) - lower) / span
        return t * Self.trackWidth
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDragging { isDragging = true }
                if dragOrigin == nil { dragOrigin = zoom }
                guard let origin = dragOrigin else { return }
                zoom = Self.clamped(origin * exp(value.translation.width / 130))
            }
            .onEnded { _ in
                dragOrigin = nil
                isDragging = false
            }
    }

    private func step(_ factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.14)) {
            zoom = Self.clamped(zoom * factor)
        }
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct AppUsageSegmentView: View {
    let run: AppUsageRun
    let width: CGFloat
    let height: Double
    @State private var resolvedColor: Color?
    @State private var resolvedColorBundleIdentifier: String?

    private var color: Color {
        if run.isIdle { return Color.white.opacity(0.08) }
        let resolved = resolvedColorBundleIdentifier == run.bundleIdentifier
            ? resolvedColor
            : nil
        return resolved ?? AppIconPalette.cachedColor(
            bundleIdentifier: run.bundleIdentifier,
            fallbackSeed: run.bundleIdentifier ?? run.applicationName
        )
    }

    private var cornerRadius: CGFloat {
        min(run.isIdle ? 3 : 9, width / 2, height / 2)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: run.isIdle
                            ? [Color.white.opacity(0.22), Color.white.opacity(0.10)]
                            : [color.opacity(0.92), color.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(run.isIdle ? 0.20 : 0.15), lineWidth: 1)
                }

            if width >= 42, !run.isIdle {
                HStack(spacing: 7) {
                    ApplicationIcon(bundleIdentifier: run.bundleIdentifier, size: 22)
                    if width >= 92 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.applicationName)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Text(DurationFormatter.short(milliseconds: run.durationMs))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.66))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .task(id: run.bundleIdentifier) {
            guard !run.isIdle else { return }
            let bundleIdentifier = run.bundleIdentifier
            let color = await AppIconPalette.colorAsync(
                bundleIdentifier: run.bundleIdentifier,
                fallbackSeed: run.bundleIdentifier ?? run.applicationName
            )
            guard !Task.isCancelled else { return }
            resolvedColor = color
            resolvedColorBundleIdentifier = bundleIdentifier
        }
    }
}

private struct ApplicationIcon: View {
    let bundleIdentifier: String?
    let size: CGFloat
    @State private var loadedIcon: NSImage?
    @State private var loadedIconBundleIdentifier: String?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .task(id: bundleIdentifier) {
            let icon = await AppIconLookup.iconAsync(bundleIdentifier: bundleIdentifier)
            guard !Task.isCancelled else { return }
            loadedIcon = icon
            loadedIconBundleIdentifier = bundleIdentifier
        }
    }

    private var icon: NSImage? {
        let loaded = loadedIconBundleIdentifier == bundleIdentifier ? loadedIcon : nil
        return loaded ?? AppIconLookup.cachedIcon(bundleIdentifier: bundleIdentifier)
    }
}

private enum DurationFormatter {
    static func short(milliseconds: Int64) -> String {
        let totalMinutes = max(Int((Double(milliseconds) / 60_000).rounded()), 1)
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

private final class ScrollWheelHostView: NSView {
    weak var coordinator: ScrollWheelMonitor.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attachDisplayLinkIfNeeded()
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> ScrollWheelHostView {
        let view = ScrollWheelHostView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: ScrollWheelHostView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.hostView = nsView
        context.coordinator.onScroll = onScroll
        context.coordinator.attachDisplayLinkIfNeeded()
    }

    static func dismantleNSView(_: ScrollWheelHostView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onScroll: (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void
        private var monitor: Any?
        private var displayLink: CADisplayLink?
        private var stressDriverTask: Task<Void, Never>?
        /// Gesture deltas awaiting the next frame — emitted 1:1, uncapped.
        /// The old ±160 accumulator with a 40-point/frame drain threw away
        /// most of every hard flick; that ceiling was the "sticky" feel.
        private var pendingDirect: CGFloat = 0
        private var pendingIsPrecise = true
        private var pendingEnd = false
        private var isScrolling = false
        private var lastEventTime: CFTimeInterval = 0
        private var lastFrameTime: CFTimeInterval = 0
        /// Opt-in release-build measurement for the stress lab. Normal app
        /// launches do not allocate samples or print anything.
        private var frameMetrics = ScrubFrameMetrics(
            enabled: ProcessInfo.processInfo.environment["AFTERRAY_UI_PERF_LOG"] == "1"
        )
        /// Our own deceleration. System momentum events are swallowed:
        /// macOS restarts momentum on every flick, whereas stacking releases
        /// is exactly the accelerate-by-repeated-swipes feel being asked for.
        private var inertia = ScrubInertia()
        private var flick = FlickSampler()

        init(onScroll: @escaping (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void) {
            self.onScroll = onScroll
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.shouldHandle(event) else { return event }
                guard let window = self.hostView?.window else { return event }
                let location = self.locationInOverlay(event, window: window)
                // Fenced regions (the history panel) own their scrolls on
                // both axes — a vertical read-scroll there must never scrub,
                // and neither must its diagonal component.
                if ScrollFenceRegistry.shared.contains(windowPoint: location, in: window) {
                    return event
                }
                let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                // Horizontal scrubs always belong to the timeline. A trailing
                // details/search NSScrollView was swallowing those events and
                // doing nothing with them — the right side felt dead.
                if !horizontal,
                   self.shouldDeferToDocumentScroll(at: location, in: window)
                {
                    return event
                }
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                let now = CACurrentMediaTime()

                if event.hasPreciseScrollingDeltas {
                    if event.momentumPhase != [] {
                        // Swallow system momentum entirely; ours replaces it.
                        return nil
                    }
                    acceptPrecise(delta: delta, phase: event.phase, at: now)
                } else {
                    pendingDirect += delta
                    pendingIsPrecise = false
                    pendingEnd = true
                    lastEventTime = now
                    isScrolling = true
                    wakeDisplayLink()
                }
                return nil
            }
            attachDisplayLinkIfNeeded()
            startStressDriverIfNeeded()
        }

        private func acceptPrecise(
            delta: CGFloat,
            phase: NSEvent.Phase,
            at now: CFTimeInterval
        ) {
            switch phase {
            case .began:
                flick.reset()
                inertia.fingerMoved(delta: Double(delta))
            case .changed:
                inertia.fingerMoved(delta: Double(delta))
                pendingDirect += delta
                flick.record(delta: Double(delta), at: now)
            case .ended:
                inertia.release(pointsPerSecond: flick.releaseVelocity(at: now))
                pendingEnd = true
            case .cancelled:
                flick.reset()
                pendingEnd = true
            default:
                // Precise deltas without phases (some mice): direct.
                pendingDirect += delta
            }
            pendingIsPrecise = true
            lastEventTime = now
            isScrolling = true
            wakeDisplayLink()
        }

        /// In-process input starts after AppKit routing and then uses exactly
        /// the production display-link/inertia path. It exists only for the
        /// release stress lab because macOS rejects synthetic HID input from
        /// unsigned test runners without Accessibility permission.
        private func startStressDriverIfNeeded() {
            let environment = ProcessInfo.processInfo.environment
            guard environment["AFTERRAY_UI_PERF_AUTORUN"] == "1" else {
                return
            }
            let delayMilliseconds = Int(environment["AFTERRAY_UI_PERF_AUTORUN_DELAY_MS"] ?? "")
                ?? 750
            stressDriverTask?.cancel()
            stressDriverTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    for flickIndex in 0..<4 {
                        guard let self else { return }
                        acceptPrecise(
                            delta: -8,
                            phase: .began,
                            at: CACurrentMediaTime()
                        )
                        for _ in 0..<18 {
                            acceptPrecise(
                                delta: CGFloat(-12 - flickIndex * 3),
                                phase: .changed,
                                at: CACurrentMediaTime()
                            )
                            try await Task.sleep(for: .milliseconds(8))
                        }
                        acceptPrecise(delta: 0, phase: .ended, at: CACurrentMediaTime())
                        try await Task.sleep(for: .milliseconds(180))
                    }
                    self?.stressDriverTask = nil
                } catch {
                    return
                }
            }
        }

        func attachDisplayLinkIfNeeded() {
            guard displayLink == nil else { return }
            let displayLink: CADisplayLink?
            if let view = hostView?.window?.contentView {
                displayLink = view.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            } else if let screen = hostView?.window?.screen {
                displayLink = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            } else {
                displayLink = nil
            }
            guard let displayLink else { return }
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
            displayLink.add(to: .main, forMode: .common)
            displayLink.isPaused = !isScrolling
            self.displayLink = displayLink
        }

        private func wakeDisplayLink() {
            attachDisplayLinkIfNeeded()
            lastFrameTime = 0
            displayLink?.isPaused = false
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            // Only a visible overlay may scrub, and only with its own
            // events. The overlay panel's frame spans the whole screen even
            // while ordered out, so the old mouse-inside-frame test was
            // always true — it swallowed every scroll destined for the
            // standalone history window and fed it to a hidden timeline.
            guard let window = hostView?.window, window.isVisible else { return false }
            if let eventWindow = event.window { return eventWindow === window }
            return window.frame.contains(NSEvent.mouseLocation)
        }

        private func locationInOverlay(_ event: NSEvent, window: NSWindow) -> NSPoint {
            if event.window === window { return event.locationInWindow }
            let screenPoint = NSEvent.mouseLocation
            return window.convertPoint(fromScreen: screenPoint)
        }

        private func shouldDeferToDocumentScroll(at point: NSPoint, in window: NSWindow) -> Bool {
            guard let hit = window.contentView?.hitTest(point),
                  let scroll = hit.enclosingScrollView
            else { return false }
            // Ignore host-wide or incidental clip views created by SwiftUI.
            let width = scroll.bounds.width
            let height = scroll.bounds.height
            guard width > 40, height > 80, width < window.frame.width * 0.72 else {
                return false
            }
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            stressDriverTask?.cancel()
            stressDriverTask = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func displayLinkDidFire(_ link: CADisplayLink) {
            let now = link.timestamp
            let previousFrameTime = lastFrameTime
            let frameInterval = previousFrameTime == 0 ? nil : now - previousFrameTime
            let dt = frameInterval.map { min($0, 0.05) } ?? (1.0 / 120.0)
            lastFrameTime = now

            // Direct gesture movement passes through whole — the finger is
            // the authority — and the glide integrates on top.
            let direct = pendingDirect
            pendingDirect = 0
            let glide = CGFloat(inertia.step(dt: dt))
            let delta = direct + glide
            if delta != 0 {
                let handlerStart = CACurrentMediaTime()
                onScroll(delta, pendingIsPrecise, false)
                frameMetrics.record(
                    frameInterval: frameInterval,
                    handlerDuration: CACurrentMediaTime() - handlerStart
                )
            }

            let quiet = direct == 0 && !inertia.isCoasting
            let wentIdle = isScrolling
                && quiet
                && CACurrentMediaTime() - lastEventTime >= 0.075
            if quiet, pendingEnd || wentIdle {
                pendingEnd = false
                isScrolling = false
                let settleStart = CACurrentMediaTime()
                onScroll(0, pendingIsPrecise, true)
                frameMetrics.finish(
                    settleDuration: CACurrentMediaTime() - settleStart
                )
                lastFrameTime = 0
                link.isPaused = true
            }
        }
    }
}

/// Keeps performance evidence next to the display-link boundary being
/// budgeted. It intentionally measures callback cadence and the synchronous
/// scrub handler separately: interval spikes reveal missed scheduling/render
/// opportunities, while handler time tells us whether our own hot path spent
/// the 8.33 ms budget.
private struct ScrubFrameMetrics {
    let enabled: Bool
    private var frameIntervals: [CFTimeInterval] = []
    private var handlerDurations: [CFTimeInterval] = []

    init(enabled: Bool) {
        self.enabled = enabled
    }

    mutating func record(
        frameInterval: CFTimeInterval?,
        handlerDuration: CFTimeInterval
    ) {
        guard enabled else { return }
        if let frameInterval { frameIntervals.append(frameInterval) }
        handlerDurations.append(handlerDuration)
    }

    mutating func finish(settleDuration: CFTimeInterval) {
        guard enabled, !handlerDurations.isEmpty else { return }
        let intervals = frameIntervals.sorted()
        let handlers = handlerDurations.sorted()
        let meanInterval = intervals.isEmpty
            ? 0
            : intervals.reduce(0, +) / Double(intervals.count)
        let refreshRate = meanInterval > 0 ? 1 / meanInterval : 0
        let overTwelvePointFiveMs = intervals.lazy.filter { $0 > 0.0125 }.count
        let overSixteenPointSevenMs = intervals.lazy.filter { $0 > 1.0 / 60.0 }.count
        print(
            String(
                format: "[afterray-ui-perf] callbacks=%d hz=%.1f interval_p95_ms=%.2f interval_max_ms=%.2f over_12.5ms=%d over_16.7ms=%d handler_p95_ms=%.3f handler_max_ms=%.3f settle_ms=%.3f",
                handlerDurations.count,
                refreshRate,
                percentile(intervals, 0.95) * 1_000,
                (intervals.last ?? 0) * 1_000,
                overTwelvePointFiveMs,
                overSixteenPointSevenMs,
                percentile(handlers, 0.95) * 1_000,
                (handlers.last ?? 0) * 1_000,
                settleDuration * 1_000
            )
        )
        frameIntervals.removeAll(keepingCapacity: true)
        handlerDurations.removeAll(keepingCapacity: true)
    }

    private func percentile(_ sorted: [CFTimeInterval], _ fraction: Double) -> CFTimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let index = min(Int((Double(sorted.count - 1) * fraction).rounded(.up)), sorted.count - 1)
        return sorted[index]
    }
}

private enum RecallDetailsPage: Equatable {
    case root
    case ocr
    case transcript
    case accessibility
}

private struct TranscriptCaption: View {
    let text: String?
    let canPlay: Bool
    let isPlaying: Bool
    let isBuffering: Bool
    let onToggleAudio: () -> Void

    private var transcript: String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var playHelp: String {
        if isBuffering { return "Cancel audio" }
        if isPlaying { return "Pause audio" }
        return "Play audio from this moment"
    }

    var body: some View {
        if let transcript {
            HStack(alignment: .center, spacing: 12) {
                if canPlay {
                    Button(action: onToggleAudio) {
                        ZStack {
                            if isBuffering {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(RecallPalette.ray.opacity(0.92), in: Circle())
                    }
                    .buttonStyle(RecallPressButtonStyle())
                    .help(playHelp)
                }
                Text(transcript)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 760)
            .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct RecallDetailsMenu: View {
    let moment: RecallMoment
    @Binding var page: RecallDetailsPage
    let isProcessing: Bool
    let artifactLoader: RecallArtifactLoader?
    let onToggleAudio: ((RecallMoment) -> Void)?
    let isAudioPlaying: Bool
    let isAudioBuffering: Bool
    let playingAudioArtifactID: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            Group {
                switch page {
                case .root:
                    rootList
                case .ocr:
                    RecallDetailsTextPage(
                        title: "On Screen",
                        text: moment.ocrText,
                        emptyText: isProcessing ? "OCR is processing…" : "No screen text found",
                        fileName: "afterray-ocr.txt"
                    )
                case .transcript:
                    RecallDetailsTextPage(
                        title: "Heard",
                        text: moment.transcriptText,
                        emptyText: isProcessing ? "Transcript is processing…" : "No transcript near this moment",
                        fileName: "afterray-transcript.txt"
                    )
                case .accessibility:
                    RecallDetailsAccessibilityPage(
                        artifactID: moment.accessibilityArtifactId,
                        loader: artifactLoader
                    )
                }
            }
            .frame(maxHeight: 320, alignment: .top)
        }
        .frame(width: 340)
        .recallGlass(in: .rounded(12))
        .onChange(of: moment.id) { _, _ in
            page = .root
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page != .root {
                Button {
                    page = .root
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(page == .root ? "CAPTURED CONTEXT" : pageTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var pageTitle: String {
        switch page {
        case .root: "CAPTURED CONTEXT"
        case .ocr: "ON SCREEN"
        case .transcript: "HEARD"
        case .accessibility: "ACCESSIBILITY TREE"
        }
    }

    private var rootList: some View {
        ScrollView {
            VStack(spacing: 4) {
                detailsRow(
                    icon: "app.badge",
                    title: moment.applicationName ?? "Unknown app",
                    subtitle: moment.bundleIdentifier ?? "No bundle identifier"
                )
                detailsRow(
                    icon: "text.viewfinder",
                    title: "On Screen",
                    subtitle: preview(moment.ocrText, empty: isProcessing ? "Processing…" : "No screen text")
                ) {
                    page = .ocr
                }
                detailsRow(
                    icon: "waveform",
                    title: "Heard",
                    subtitle: preview(moment.transcriptText, empty: isProcessing ? "Processing…" : "No transcript")
                ) {
                    page = .transcript
                }
                detailsRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Accessibility tree",
                    subtitle: moment.accessibilityArtifactId == nil
                        ? "No snapshot for this moment"
                        : "Full AX JSON for this screen"
                ) {
                    page = .accessibility
                }
                if moment.hasVisibleTranscript, moment.audioArtifactId != nil {
                    let isThis = moment.audioArtifactId == playingAudioArtifactID
                    Button {
                        onToggleAudio?(moment)
                    } label: {
                        Label(detailsAudioTitle(isThis: isThis), systemImage: detailsAudioSymbol(isThis: isThis))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RecallCapsuleButtonStyle())
                    .disabled(onToggleAudio == nil)
                    .padding(.top, 8)
                }
            }
            .padding(12)
        }
    }

    private func detailsRow(
        icon: String,
        title: String,
        subtitle: String,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RecallPalette.ray)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func preview(_ text: String?, empty: String) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return empty }
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    private func detailsAudioTitle(isThis: Bool) -> String {
        if isThis && isAudioBuffering { return "Cancel audio" }
        if isThis && isAudioPlaying { return "Pause audio" }
        return "Play from this moment"
    }

    private func detailsAudioSymbol(isThis: Bool) -> String {
        if isThis && isAudioBuffering { return "stop.fill" }
        if isThis && isAudioPlaying { return "pause.fill" }
        return "play.fill"
    }
}

private struct RecallDetailsTextPage: View {
    let title: String
    let text: String?
    let emptyText: String
    let fileName: String

    private var displayText: String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? emptyText : trimmed
    }

    private var hasContent: Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasContent {
                HStack(spacing: 8) {
                    Button("Copy") { RecallTextActions.copy(displayText) }
                    Button("Open") { RecallTextActions.open(displayText, name: fileName) }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(RecallPalette.ray)
                .padding(.horizontal, 16)
            }

            ScrollView {
                Text(displayText)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(hasContent ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .padding(.top, 10)
    }
}

private struct RecallDetailsAccessibilityPage: View {
    let artifactID: String?
    let loader: RecallArtifactLoader?
    @State private var snapshot = ""

    var body: some View {
        RecallDetailsTextPage(
            title: "Accessibility tree",
            text: snapshotText,
            emptyText: emptyText,
            fileName: "afterray-accessibility.json"
        )
        .task(id: artifactID) {
            snapshot = ""
            guard let artifactID, let loader else { return }
            snapshot = " "
            guard let data = try? await loader(artifactID) else {
                snapshot = ""
                return
            }
            if
                let object = try? JSONSerialization.jsonObject(with: data),
                let pretty = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys]
                )
            {
                snapshot = String(decoding: pretty, as: UTF8.self)
            } else {
                snapshot = String(decoding: data, as: UTF8.self)
            }
        }
    }

    private var snapshotText: String? {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : snapshot
    }

    private var emptyText: String {
        if artifactID == nil { return "No snapshot for this moment" }
        if snapshot == " " { return "Loading…" }
        return "The snapshot could not be loaded."
    }
}

private enum RecallTextActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ text: String, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            copy(text)
        }
    }
}

private struct EmptyRecallView: View {
    let isProcessing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(RecallPalette.ray)
                    .frame(width: 18, height: 2)
                Text(isProcessing ? "PREPARING FIRST MOMENT" : "CAPTURE IS READY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RecallPalette.ray)
            }
            Text(isProcessing ? "The first moments are being prepared" : "Your day begins here")
                .font(.system(size: 24, weight: .semibold))
            Text(isProcessing ? "Keep AfterRay running for a moment." : "AfterRay is capturing automatically. Your first screen will appear shortly.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(28)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.36), radius: 24, y: 10)
    }
}

private struct FailureView: View {
    let message: String
    let onReload: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                Text("LOCAL SERVICE UNAVAILABLE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
            }
            .foregroundStyle(RecallPalette.ray)
            Text("Couldn’t open your memory")
                .font(.system(size: 24, weight: .semibold))
            Text("The local AfterRay daemon failed to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: 460, alignment: .leading)
            if let onReload {
                HStack {
                    Spacer()
                    Button("Try Again", action: onReload)
                        .buttonStyle(RecallCapsuleButtonStyle())
                }
            }
        }
        .padding(28)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 24, y: 10)
    }
}

private struct RecallPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct RecallCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(RecallPalette.ray.opacity(configuration.isPressed ? 0.68 : 0.86), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

public enum RecallPalette {
    public static let background = Color(red: 0.018, green: 0.016, blue: 0.020)
    public static let ray = Color(red: 1.0, green: 0.20, blue: 0.14)
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.82)
    public static let textTertiary = Color.white.opacity(0.66)
    public static let panelDim = Color.black.opacity(0.58)
    public static let panelStroke = Color.white.opacity(0.16)

    public static func appColor(seed: String) -> Color {
        let palette = [
            Color(red: 0.93, green: 0.20, blue: 0.14),
            Color(red: 0.86, green: 0.34, blue: 0.16),
            Color(red: 0.68, green: 0.23, blue: 0.42),
            Color(red: 0.38, green: 0.34, blue: 0.72),
            Color(red: 0.19, green: 0.46, blue: 0.58),
            Color(red: 0.26, green: 0.52, blue: 0.39),
        ]
        let hash = seed.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return palette[Int(UInt(bitPattern: hash) % UInt(palette.count))]
    }
}

/// Timeline swatches sampled from the app icon. Hue matches the icon;
/// saturation and lightness are the icon averages, lifted just enough
/// to stay readable on the dark track.
enum AppIconPalette {
    private static let cache = NSCache<NSString, Swatch>()
    private static let sampler = Sampler()

    /// Render-loop lookup. A cache miss returns the deterministic fallback and
    /// never asks Launch Services or samples pixels synchronously.
    static func cachedColor(bundleIdentifier: String?, fallbackSeed: String) -> Color {
        if let bundleIdentifier {
            if let cached = cache.object(forKey: bundleIdentifier as NSString) {
                return cached.color.map(Color.init(nsColor:))
                    ?? RecallPalette.appColor(seed: fallbackSeed)
            }
        }
        return RecallPalette.appColor(seed: fallbackSeed)
    }

    static func colorAsync(bundleIdentifier: String?, fallbackSeed: String) async -> Color {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return RecallPalette.appColor(seed: fallbackSeed)
        }
        if let cached = cache.object(forKey: bundleIdentifier as NSString) {
            return cached.color.map(Color.init(nsColor:))
                ?? RecallPalette.appColor(seed: fallbackSeed)
        }
        let sample = await sampler.sample(bundleIdentifier: bundleIdentifier)
        let swatch: Swatch
        switch sample {
        case .color(let red, let green, let blue):
            swatch = Swatch(
                NSColor(
                    calibratedRed: CGFloat(red),
                    green: CGFloat(green),
                    blue: CGFloat(blue),
                    alpha: 1
                )
            )
        case .missing:
            swatch = Swatch(nil)
        }
        cache.setObject(swatch, forKey: bundleIdentifier as NSString)
        return swatch.color.map(Color.init(nsColor:))
            ?? RecallPalette.appColor(seed: fallbackSeed)
    }

    private static func averageHSL(from image: NSImage) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat)? {
        let edge = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: edge,
            pixelsHigh: edge,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: edge * 4,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: edge, height: edge),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var sine: CGFloat = 0
        var cosine: CGFloat = 0
        var saturation: CGFloat = 0
        var lightness: CGFloat = 0
        var count: CGFloat = 0

        for y in 0..<edge {
            for x in 0..<edge {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                guard alpha > 0.20 else { continue }
                let hsl = RecallColorMath.hsl(red: red, green: green, blue: blue)
                // Skip chrome that does not carry the brand hue.
                guard hsl.saturation > 0.10, hsl.lightness > 0.08, hsl.lightness < 0.92 else {
                    continue
                }
                let radians = hsl.hue * 2 * .pi
                sine += sin(radians)
                cosine += cos(radians)
                saturation += hsl.saturation
                lightness += hsl.lightness
                count += 1
            }
        }
        guard count > 0 else { return nil }
        var hue = atan2(sine / count, cosine / count) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (hue, saturation / count, lightness / count)
    }

    private final class Swatch: NSObject {
        let color: NSColor?
        init(_ color: NSColor?) { self.color = color }
    }

    private enum Sample: Sendable {
        case color(red: Double, green: Double, blue: Double)
        case missing
    }

    private actor Sampler {
        private var resolved: [String: Sample] = [:]
        private var inFlight: [String: Task<Sample, Never>] = [:]

        func sample(bundleIdentifier: String) async -> Sample {
            if let resolved = resolved[bundleIdentifier] { return resolved }
            if let existing = inFlight[bundleIdentifier] { return await existing.value }
            let task = Task<Sample, Never> {
                guard let icon = await AppIconLookup.iconAsync(bundleIdentifier: bundleIdentifier) else {
                    return .missing
                }
                return await Task.detached(priority: .utility) {
                    guard let hsl = AppIconPalette.averageHSL(from: icon) else {
                        return Sample.missing
                    }
                    let rgb = RecallColorMath.rgb(
                        hue: hsl.hue,
                        saturation: min(max(hsl.saturation, 0.38), 0.90),
                        lightness: min(max(hsl.lightness, 0.36), 0.62)
                    )
                    return Sample.color(
                        red: Double(rgb.red),
                        green: Double(rgb.green),
                        blue: Double(rgb.blue)
                    )
                }.value
            }
            inFlight[bundleIdentifier] = task
            let result = await task.value
            inFlight[bundleIdentifier] = nil
            resolved[bundleIdentifier] = result
            return result
        }
    }
}

enum RecallColorMath {
    static func hsl(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0.000_1 else {
            return (0, 0, lightness)
        }
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        let hue: CGFloat
        if maximum == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        return (hue / 6, saturation, lightness)
    }

    static func rgb(
        hue: CGFloat,
        saturation: CGFloat,
        lightness: CGFloat
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard saturation > 0.000_1 else {
            return (lightness, lightness, lightness)
        }
        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        return (
            channel(p: p, q: q, t: hue + 1 / 3),
            channel(p: p, q: q, t: hue),
            channel(p: p, q: q, t: hue - 1 / 3)
        )
    }

    private static func channel(p: CGFloat, q: CGFloat, t: CGFloat) -> CGFloat {
        var wrapped = t
        if wrapped < 0 { wrapped += 1 }
        if wrapped > 1 { wrapped -= 1 }
        if wrapped < 1 / 6 { return p + (q - p) * 6 * wrapped }
        if wrapped < 1 / 2 { return q }
        if wrapped < 2 / 3 { return p + (q - p) * (2 / 3 - wrapped) * 6 }
        return p
    }
}

public extension View {
    func recallOverlayPanel(cornerRadius: CGFloat) -> some View {
        recallGlass(in: .rounded(cornerRadius))
    }
}
