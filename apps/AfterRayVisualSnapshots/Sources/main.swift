import AfterRayMockData
import AfterRayRecall
import AppKit
import SwiftUI

/// Renders recall surfaces to PNG offscreen, on mock data only.
///
/// The Visual Lab is for a human with a mouse; this is for reviewing pixels in
/// a terminal, in CI, or from an agent. Nothing here starts the daemon, asks
/// for a permission, or captures a screen.
///
/// One known blind spot: the full-resolution still is drawn by an
/// `AVSampleBufferDisplayLayer`, which does not render through
/// `cacheDisplay(in:to:)`. Chrome snapshots therefore show every overlay over
/// an empty picture. The `highlight-*` scenes exist to cover what that hides —
/// they draw a real mock frame and place boxes with the same `OcrHighlight`
/// math the app uses.
@MainActor
enum SnapshotRunner {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // The overlay only ever runs dark. Without this the offscreen host
        // defaults to Aqua and unstyled labels render black on black.
        application.appearance = NSAppearance(named: .darkAqua)

        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? "/tmp/afterray-snapshots"
        )
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // Mirror the running app, where the timeline segments have already
        // put every icon in the shared cache before the panel is built: the
        // panel then takes the synchronous cache path, not the async one.
        for identifier in [
            "com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Terminal",
            "com.figma.Desktop", "com.tinyspeck.slackmacgap", "com.apple.mail",
        ] {
            _ = AppIconLookup.icon(bundleIdentifier: identifier)
        }

        for scene in SnapshotScene.all {
            let url = outputDirectory.appendingPathComponent("\(scene.name).png")
            render(scene: scene, to: url)
            print("wrote \(url.path)")
        }
        print("\n\(SnapshotScene.all.count) snapshot(s) in \(outputDirectory.path)")
    }

    private static func render(scene: SnapshotScene, to url: URL) {
        let window = NSWindow(
            // Far offscreen: the view must be in a window to lay out and to run
            // its `.task` blocks, but it must never appear on a display.
            contentRect: NSRect(x: -30_000, y: -30_000, width: scene.size.width, height: scene.size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: scene.content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: scene.size)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Let async work land: thumbnail decodes, `.task` blocks, and the
        // highlight blink settling on its resting opacity.
        pumpRunLoop(seconds: scene.settleSeconds)

        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("!! could not allocate a bitmap for \(scene.name)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("!! could not encode \(scene.name)")
            return
        }
        try? png.write(to: url)
        window.orderOut(nil)
    }

    private static func pumpRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

struct SnapshotScene {
    let name: String
    let size: CGSize
    let settleSeconds: TimeInterval
    let content: AnyView

    @MainActor
    static var all: [SnapshotScene] {
        chromeScenes + highlightScenes + stampScene + settingsScenes + historyPanelScene
            + captionScenes
    }
}

// MARK: - Real RecallView, driven by mock data

@MainActor
private func chromeScene(
    name: String,
    size: CGSize = CGSize(width: 1_440, height: 900),
    moments: [RecallMoment],
    session: RecallSearchSession?,
    playheadMs: Int64
) -> SnapshotScene {
    SnapshotScene(
        name: name,
        size: size,
        settleSeconds: 2.2,
        content: AnyView(
            RecallView(
                moments: moments,
                playheadMs: .constant(playheadMs),
                isLive: .constant(false),
                imageLoader: MockArtifactFactory.loader,
                onOpenSettings: {},
                recordingState: .recording,
                onToggleRecording: {},
                daySummary: .mockRich(around: playheadMs),
                searchSession: session,
                thumbnailLoader: MockSearchData.thumbnailLoader,
                ocrLoader: MockSearchData.ocrLoader
            )
            .frame(width: size.width, height: size.height)
        )
    )
}

@MainActor
private var chromeScenes: [SnapshotScene] {
    let searchMoments = RecallScenario.search.moments
    let session = RecallScenario.search.searchSession

    var scenes: [SnapshotScene] = []

    // Newest match selected — what you see right after pressing return.
    if let session, let first = session.selectedFrame,
       let moment = searchMoments.first(where: { $0.id == first.momentId })
    {
        scenes.append(
            chromeScene(
                name: "01-search-newest-selected",
                moments: searchMoments,
                session: session,
                playheadMs: moment.capturedAtMs
            )
        )
    }

    // Mid-strip: cells on both sides of the playhead, older stamps in view.
    if var session, session.frames.count > 6 {
        session.selectedIndex = 5
        if let moment = searchMoments.first(where: {
            $0.id == session.frames[5].momentId
        }) {
            scenes.append(
                chromeScene(
                    name: "02-search-middle-selected",
                    moments: searchMoments,
                    session: session,
                    playheadMs: moment.capturedAtMs
                )
            )
        }
    }

    // Oldest match: the strip has run out on the right.
    if var session, let last = session.frames.indices.last {
        session.selectedIndex = last
        if let moment = searchMoments.first(where: {
            $0.id == session.frames[last].momentId
        }) {
            scenes.append(
                chromeScene(
                    name: "03-search-oldest-selected",
                    moments: searchMoments,
                    session: session,
                    playheadMs: moment.capturedAtMs
                )
            )
        }
    }

    // Small result sets: the strip must not look broken with one or two cells.
    for count in [1, 2, 3] {
        let subset = Array(searchMoments.suffix(count))
        let hits = subset.map { moment in
            RecallSearchHit(
                momentId: moment.id,
                sessionId: "session-search",
                capturedAtMs: moment.capturedAtMs,
                source: "ocr",
                text: moment.ocrText ?? "",
                score: 1
            )
        }
        if let session = RecallSearchSession.make(query: "Moment", hits: hits),
           let selected = session.selectedFrame,
           let moment = subset.first(where: { $0.id == selected.momentId })
        {
            scenes.append(
                chromeScene(
                    name: "04-search-\(count)-result",
                    moments: searchMoments,
                    session: session,
                    playheadMs: moment.capturedAtMs
                )
            )
        }
    }

    // No search: the app timeline must be untouched by all of this.
    let longDay = RecallScenario.long.moments
    scenes.append(
        chromeScene(
            name: "05-no-search-app-timeline",
            moments: longDay,
            session: nil,
            playheadMs: longDay[40].capturedAtMs
        )
    )

    // Header stress: the identity capsule with no title, a normal title, and a
    // title long enough to threaten the rest of the chrome row.
    scenes.append(contentsOf: headerScenes())

    // A narrow window, where the filmstrip has least room.
    if let session {
        scenes.append(
            chromeScene(
                name: "09-search-narrow-window",
                size: CGSize(width: 900, height: 640),
                moments: searchMoments,
                session: session,
                playheadMs: searchMoments.last?.capturedAtMs ?? 0
            )
        )
    }

    return scenes
}

@MainActor
private func headerScenes() -> [SnapshotScene] {
    let titles: [(String, String?)] = [
        ("06-header-no-title", nil),
        ("07-header-normal-title", "RecallView.swift — AfterRay"),
        (
            "08-header-very-long-title",
            "Q3 planning · roadmap review · search presentation and timeline rebuild — Google Docs"
        ),
    ]
    return titles.map { name, title in
        let moment = RecallMoment(
            id: "header-moment",
            sessionId: "session-header",
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            imageArtifactId: "mock://frame/1",
            isFavorite: false,
            ocrText: "Header check",
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: title
        )
        return chromeScene(
            name: name,
            size: CGSize(width: 1_280, height: 420),
            moments: [moment],
            session: nil,
            playheadMs: moment.capturedAtMs
        )
    }
}

// MARK: - Highlight geometry over a real picture

/// Draws a mock frame exactly as the app letterboxes it, with boxes placed by
/// the shipping `OcrHighlight` math.
///
/// `.resizeAspect` on the video layer and `.aspectRatio(contentMode: .fit)`
/// here produce the same rectangle, so if a box sits on the glyphs in this
/// picture it sits on them in the app.
private struct HighlightProof: View {
    let image: NSImage
    let regions: [OcrRegion]
    let query: String

    var body: some View {
        GeometryReader { geometry in
            let pixelSize = image.size
            let content = OcrHighlight.contentRect(
                pixelSize: pixelSize,
                viewSize: geometry.size
            )
            let matched = OcrHighlight.matching(regions: regions, query: query)

            ZStack(alignment: .topLeading) {
                Color.black
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // Every region in white so the letterbox mapping is visible,
                // then the query matches in ray red on top.
                ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                    box(OcrHighlight.rect(for: region, in: content), color: .white.opacity(0.5))
                }
                ForEach(Array(matched.enumerated()), id: \.offset) { _, region in
                    box(OcrHighlight.rect(for: region, in: content), color: RecallPalette.ray)
                }

                Rectangle()
                    .strokeBorder(.cyan.opacity(0.7), lineWidth: 1)
                    .frame(width: content.width, height: content.height)
                    .offset(x: content.minX, y: content.minY)
            }
        }
    }

    private func box(_ rect: CGRect, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(color, lineWidth: 2)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}

@MainActor
private var highlightScenes: [SnapshotScene] {
    guard
        let data = try? MockArtifactFactory.renderFrame(index: 2),
        let image = NSImage(data: data)
    else { return [] }

    let regions = [MockSearchData.titleRegion, MockSearchData.bodyRegion]

    // The mock frame is 1280x800. Each view aspect exercises a different branch
    // of the letterbox: bars top/bottom, bars left/right, and an exact fit.
    let cases: [(String, CGSize)] = [
        ("10-highlight-letterbox-tall-view", CGSize(width: 900, height: 900)),
        ("11-highlight-letterbox-wide-view", CGSize(width: 1_400, height: 620)),
        ("12-highlight-exact-fit", CGSize(width: 1_280, height: 800)),
    ]

    return cases.map { name, size in
        SnapshotScene(
            name: name,
            size: size,
            settleSeconds: 0.4,
            content: AnyView(
                HighlightProof(image: image, regions: regions, query: MockSearchData.query)
                    .frame(width: size.width, height: size.height)
            )
        )
    }
}

// MARK: - Relative stamps

/// The caption ladder on its own, so the wording can be judged without hunting
/// across filmstrip cells.
private struct StampLadder: View {
    private let now = Int64(Date().timeIntervalSince1970 * 1_000)
    private let ages: [(String, Int64)] = [
        ("just now", 5_000),
        ("1 min", 60_000),
        ("7 min", 7 * 60_000),
        ("59 min", 59 * 60_000),
        ("1 hour", 3_600_000),
        ("9 hours", 9 * 3_600_000),
        ("1 day", 86_400_000),
        ("6 days", 6 * 86_400_000),
        ("2 weeks", 14 * 86_400_000),
        ("1 year", 365 * 86_400_000),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RelativeStamp.short")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(ages, id: \.0) { label, age in
                HStack(spacing: 14) {
                    Text(RelativeStamp.short(fromMs: now - age, nowMs: now))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 56, alignment: .leading)
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RecallPalette.background)
    }
}

@MainActor
private var stampScene: [SnapshotScene] {
    [
        SnapshotScene(
            name: "13-relative-stamps",
            size: CGSize(width: 340, height: 400),
            settleSeconds: 0.3,
            content: AnyView(StampLadder())
        )
    ]
}

/// The history panel with titles and bullets long enough to wrap, at the
/// narrowest width it ships in. Wrapping is where a document layout goes
/// wrong: every wrapped line must land on the same edge as its first line,
/// and the timeline rule must stay continuous through all of it.
@MainActor
private var historyPanelScene: [SnapshotScene] {
    let slotMs = DaySummaryLayout.slotDurationMs
    let dayStart: Int64 = 1_786_665_600_000
    let now = dayStart + 13 * 3_600_000

    func slot(
        index: Int64,
        title: String?,
        bullets: [String] = [],
        state: String = "done",
        apps: [DayAppFact] = [
            DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 900_000),
            DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 420_000),
        ]
    ) -> DaySlotSummary {
        DaySlotSummary(
            slotStartMs: dayStart + index * slotMs,
            slotEndMs: dayStart + (index + 1) * slotMs,
            state: state,
            facts: DaySlotFacts(apps: apps, momentCount: 24),
            title: title,
            bullets: bullets.isEmpty ? nil : bullets
        )
    }

    let today = DaySummary(
        day: DaySummaryLayout.localDayKey(ms: dayStart),
        dayStartMs: dayStart,
        dayEndMs: dayStart + 86_400_000,
        slots: [
            // Every way an icon fails to resolve: no bundle id at all, and a
            // bundle id Launch Services has never heard of. Both must take no
            // room on the metadata line rather than leaving a mark.
            slot(index: 24, title: nil, state: "degraded", apps: [
                DayAppFact(name: "unknown", bundleIdentifier: nil, ms: 40_000),
                DayAppFact(name: "Lody", bundleIdentifier: "ai.lody.app", ms: 780_000),
            ]),
            slot(
                index: 25,
                title: "Debugging Lody search logic and publishing AfterRay packages",
                bullets: [
                    "Search logic fix: resolved the issue where UI search returned exactly 60 matches by adding a cosine similarity floor (0.72) and fixing Chinese tokenisation in FTS5 to avoid semantic noise filling results.",
                    "Website and package publish: iterated on the home page design and SEO metrics, then configured the Cloudflare domain to prepare for uploading the site.",
                ]
            ),
            slot(
                index: 26,
                title: "Lody search logic debug and overlay scroll listener fix",
                bullets: [
                    "Identified that UI search returned a fixed daemon candidate pool rather than similarity scores.",
                ],
                apps: [
                    DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 900_000),
                    DayAppFact(name: "unknown", bundleIdentifier: nil, ms: 20_000),
                    DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 420_000),
                ]
            ),
        ]
    )
    let yesterday = DaySummary(
        day: DaySummaryLayout.localDayKey(ms: dayStart - 86_400_000),
        dayStartMs: dayStart - 86_400_000,
        dayEndMs: dayStart,
        slots: [
            slot(index: -4, title: "Read the GOP packer end to end", bullets: ["Length check was reading the IVF header twice."]),
        ]
    )

    return [
        SnapshotScene(
            name: "16-history-panel-wrapping",
            size: CGSize(width: 380, height: 720),
            settleSeconds: 1.0,
            content: AnyView(
                DaySummaryPanel(
                    style: .window,
                    summaries: [today, yesterday],
                    playheadMs: dayStart + 25 * slotMs + 60_000,
                    nowMs: now,
                    hasMore: false,
                    isLoadingMore: false,
                    followPulse: 0,
                    onSelectSlot: { _ in },
                    onLoadMore: {}
                )
                .frame(width: 380, height: 720)
            )
        ),
    ]
}

MainActor.assumeIsolated { SnapshotRunner.main() }


/// The exclusion lists, rendered offscreen. They are the one settings surface
/// where being wrong is a privacy failure rather than an annoyance, so they get
/// checked against pixels rather than assumed from the code.
@MainActor
private var settingsScenes: [SnapshotScene] {
    let empty = SettingsPreviewModel()
    let filled = SettingsPreviewModel()
    filled.excludedBundleIds = ["com.tencent.xinWeChat", "com.tinyspeck.slackmacgap"]
    filled.excludedDomains = ["bank.example", "mail.example.com"]
    return [
        settingsScene(name: "14-settings-exclusions-empty", model: empty),
        settingsScene(name: "15-settings-exclusions-filled", model: filled),
    ]
}

/// The transcript caption with the summary panel open. The panel is the
/// tallest thing in the bottom stack, so this is where the caption either
/// stays with the timeline or gets pushed away from it.
@MainActor
private var captionScenes: [SnapshotScene] {
    let long = """
        Thank you very much. 他改革的成像也大多在他退休之后才愈发显现出来 这种工程不必在我的宽广胸襟和他极恶如愁的\
        真心情一样 让人难忘 动容 1988年任上海市长时他曾说过这样一段话 我是一个孤儿 我的父母很早就死了 我没有见过我的父亲 \
        我也没有兄弟姐妹 我1947年找到了党 觉得党就是我的母亲 所以我讲什么话都没有顾忌 只要对得起党
        """
    let moments = RecallScenario.long.moments.map { moment in
        RecallMoment(
            id: moment.id,
            sessionId: moment.sessionId,
            capturedAtMs: moment.capturedAtMs,
            imageArtifactId: moment.imageArtifactId,
            ocrText: moment.ocrText,
            transcriptText: long,
            audioArtifactId: "mock://audio/\(moment.id)",
            applicationName: moment.applicationName,
            bundleIdentifier: moment.bundleIdentifier
        )
    }
    let playheadMs = moments[40].capturedAtMs
    return [(1_440, 900), (1_512, 760)].map { width, height in
        SnapshotScene(
            name: "17-caption-summary-open-\(width)x\(height)",
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            settleSeconds: 2.2,
            content: AnyView(
                RecallView(
                    moments: moments,
                    playheadMs: .constant(playheadMs),
                    isLive: .constant(false),
                    imageLoader: MockArtifactFactory.loader,
                    onOpenSettings: {},
                    recordingState: .recording,
                    onToggleRecording: {},
                    daySummary: .mockRich(around: playheadMs)
                )
                .frame(width: CGFloat(width), height: CGFloat(height))
            )
        )
    }
}

@MainActor
private func settingsScene(name: String, model: SettingsPreviewModel) -> SnapshotScene {
    SnapshotScene(
        name: name,
        size: CGSize(width: 900, height: 700),
        settleSeconds: 1.2,
        content: AnyView(
            AfterRaySettingsView(model: model, onClose: {}, initialPage: .general)
                .frame(width: 900, height: 700)
        )
    )
}
