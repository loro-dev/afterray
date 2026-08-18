import AfterRayRecall
import AppKit
import Foundation

public enum RecallScenario: String, CaseIterable, Identifiable, Sendable {
    case empty
    case short
    case long
    case stress
    case processing
    case favorites
    case search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .empty: "Empty"
        case .short: "Short"
        case .long: "Long day"
        case .stress: "20K GOP stress"
        case .processing: "Processing"
        case .favorites: "Favorites"
        case .search: "Search"
        }
    }

    public var moments: [RecallMoment] {
        switch self {
        case .empty: []
        case .short: Self.makeMoments(count: 7)
        case .long: Self.makeMoments(count: 84)
        case .stress: Self.stressMoments
        case .processing: Self.makeMoments(count: 11, processing: true)
        case .favorites: Self.makeMoments(count: 22, favoriteEvery: 4)
        case .search: MockSearchData.moments
        }
    }

    /// Non-nil puts `RecallView` in search mode, showing the filmstrip.
    public var searchSession: RecallSearchSession? {
        self == .search ? MockSearchData.session : nil
    }

    public var loadState: RecallLoadState {
        self == .processing ? .processing(message: "OCR and transcript are catching up") : .ready
    }

    public var daySummary: DaySummary {
        switch self {
        case .empty:
            let bounds = DaySummaryLayout.dayBounds(ms: Self.baseMs)
            return DaySummary(day: DaySummaryLayout.localDayKey(ms: Self.baseMs), dayStartMs: bounds.start, dayEndMs: bounds.end, slots: [])
        case .short:
            return .mockFactsOnly(around: Self.baseMs)
        case .long, .stress, .processing, .favorites, .search:
            return .mockRich(around: Self.baseMs)
        }
    }

    static let baseMs: Int64 = 1_786_483_800_000
    private static let stressMoments = makeGopMoments(count: 20_000)

    private static func makeMoments(
        count: Int,
        processing: Bool = false,
        favoriteEvery: Int? = nil
    ) -> [RecallMoment] {
        let base = Self.baseMs
        let screenCopy = [
            "Reviewing the capture pipeline and its retry policy.",
            "Timeline interaction: drag horizontally to move through the day.",
            "The local model queue is idle and all artifacts are available.",
            "Comparing layout options for the first Recall experience.",
        ]
        let transcriptCopy = [
            "Let's keep the first version narrow and make the core interaction feel exceptional.",
            "The daemon should own storage while the interface stays replaceable.",
            "We can validate this with a real day of recording before adding more product surface.",
        ]
        // Browser entries carry a URL so the identity capsule's clickable
        // address is drivable from the labs and snapshots; the rest leave it
        // nil, which is the window-title path.
        let applications: [(name: String, bundle: String, url: String?)] = [
            ("Figma", "com.figma.Desktop", nil),
            ("Safari", "com.apple.Safari", "https://www.example.com/moments/capture-pipeline?ref=recall"),
            ("Xcode", "com.apple.dt.Xcode", nil),
            ("Slack", "com.tinyspeck.slackmacgap", nil),
            ("Notion", "notion.id", nil),
        ]
        return (0..<count).map { index in
            let app = applications[min(index / 7, applications.count - 1) % applications.count]
            return RecallMoment(
                id: "moment-\(index)",
                sessionId: "session-today",
                capturedAtMs: base + Int64(index * 42_000),
                imageArtifactId: "mock://frame/\(index)",
                isFavorite: favoriteEvery.map { index.isMultiple(of: $0) } ?? false,
                ocrText: processing && index > count - 4 ? nil : screenCopy[index % screenCopy.count],
                transcriptText: processing && index > count - 6 ? nil : transcriptCopy[index % transcriptCopy.count],
                audioArtifactId: index.isMultiple(of: 3) ? "mock://audio/\(index)" : nil,
                applicationName: app.name,
                bundleIdentifier: app.bundle,
                url: app.url
            )
        }
    }

    /// Large enough to expose O(n)-per-frame work and shaped like the cold
    /// archive: twelve moments share one GOP and have no leftover JPEG still.
    private static func makeGopMoments(count: Int) -> [RecallMoment] {
        let applications = [
            ("Figma", "com.figma.Desktop"),
            ("Safari", "com.apple.Safari"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Slack", "com.tinyspeck.slackmacgap"),
        ]
        return (0..<count).map { index in
            let gopIndex = UInt16(index % 12)
            let segment = index / 12
            let app = applications[(index / 90) % applications.count]
            return RecallMoment(
                id: "stress-moment-\(index)",
                sessionId: "stress-session",
                capturedAtMs: baseMs + Int64(index * 10_000),
                gop: RecallGopRef(
                    segmentId: "mock-segment-\(segment)",
                    index: gopIndex,
                    frameCount: UInt16(min(12, count - segment * 12))
                ),
                ocrText: "Stress moment \(index)",
                applicationName: app.0,
                bundleIdentifier: app.1,
                windowTitle: "Long archive · \(index)"
            )
        }
    }
}

public extension DaySummary {
    static func mockMixedSlotWeek(around nowMs: Int64) -> [DaySummary] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000)
        return (0..<7).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) ?? now
            let bounds = DaySummaryLayout.dayBounds(ms: Int64(date.timeIntervalSince1970 * 1_000))
            let ten: Int64 = 10 * 60 * 1_000
            let thirty: Int64 = 30 * 60 * 1_000
            var slots: [DaySlotSummary] = []
            var cursor = bounds.start
            while cursor < bounds.end {
                let duration: Int64
                if dayOffset < 3 {
                    duration = ten
                } else if dayOffset == 3 {
                    duration = cursor < bounds.start + (bounds.end - bounds.start) / 2 ? thirty : ten
                } else {
                    duration = thirty
                }
                let index = slots.count
                // Three card shapes live in the vault at once, so the lab
                // draws all three: v3 writes a Markdown body, v2 writes
                // threads, v1 writes bullets.
                let shape = index % 3
                let isV3 = shape == 0
                let isV2 = shape == 1
                slots.append(DaySlotSummary(
                    slotStartMs: cursor,
                    slotEndMs: min(cursor + duration, bounds.end),
                    state: "done",
                    anchorMomentId: "summary-stress-\(dayOffset)-\(index)",
                    facts: DaySlotFacts(
                        apps: [DayAppFact(name: index.isMultiple(of: 2) ? "Xcode" : "Lody", ms: duration - 60_000)],
                        momentCount: 8
                    ),
                    title: "Summary \(dayOffset + 1).\(index + 1)",
                    bullets: isV2 || isV3 ? nil : ["Legacy detail one", "Legacy detail two"],
                    category: "coding",
                    description: isV2 || isV3
                        ? "Implemented and validated one focused part of the summary sidebar."
                        : nil,
                    details: isV3
                        ? "### Implementation\nChanged the component and kept the unfinished state visible.\n\n![10:23 the failing check](afterray://moment/summary-stress-\(dayOffset)-\(index))\n\n### Left open\nRelease validation was not run."
                        : nil,
                    threads: isV2 ? [SummaryThread(name: "Implementation", prose: "Changed the component and kept the unfinished state visible.")] : nil,
                    decisions: isV2 ? ["Keep details collapsed by default."] : nil,
                    notCaptured: isV2 && index.isMultiple(of: 9) ? ["Release validation was not run."] : nil
                ))
                cursor += duration
            }
            return DaySummary(
                day: DaySummaryLayout.localDayKey(ms: bounds.start),
                dayStartMs: bounds.start,
                dayEndMs: bounds.end,
                slots: slots
            )
        }
    }

    static func mockRich(around playheadMs: Int64) -> DaySummary {
        let bounds = DaySummaryLayout.dayBounds(ms: playheadMs)
        let current = DaySummaryLayout.slotStartMs(atMs: playheadMs)
        let slot = DaySummaryLayout.slotDurationMs
        let rows: [(Int64, String?, String, [DayAppFact])] = [
            (current - 5 * slot, "Morning review of the capture retry policy", "coding", [
                DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 1_380_000),
                DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 240_000),
            ]),
            (current - 4 * slot, nil, "degraded", [
                DayAppFact(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", ms: 720_000),
                DayAppFact(name: "Mail", bundleIdentifier: "com.apple.mail", ms: 180_000),
            ]),
            (current - 3 * slot, "Design doc: slot cards vs day filmstrip", "reading", [
                DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 1_500_000),
            ]),
            (current - 2 * slot, "GOP header still failing the IVF length check", "coding", [
                DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 1_320_000),
                DayAppFact(name: "Terminal", bundleIdentifier: "com.apple.Terminal", ms: 360_000),
            ]),
            (current - slot, nil, "failed", [
                DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 900_000),
                DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 600_000),
            ]),
            (current, "Long design conversation about T1/T2", "comms", [
                DayAppFact(name: "Lody", bundleIdentifier: "ai.lody.app", ms: 1_680_000),
            ]),
            (current + slot, "cargo test after the prompt rewrite", "coding", [
                DayAppFact(name: "Terminal", bundleIdentifier: "com.apple.Terminal", ms: 840_000),
                DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 720_000),
            ]),
            (current + 2 * slot, nil, "skipped_idle", [
                DayAppFact(name: "Figma", bundleIdentifier: "com.figma.Desktop", ms: 1_200_000),
            ]),
            (current + 3 * slot, "Visual Lab pass on the day panel", "other", [
                DayAppFact(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", ms: 1_080_000),
                DayAppFact(name: "Figma", bundleIdentifier: "com.figma.Desktop", ms: 480_000),
            ]),
            (current + 4 * slot, nil, "degraded", [
                DayAppFact(name: "Safari", bundleIdentifier: "com.apple.Safari", ms: 540_000),
            ]),
        ]
        let slots = rows
            .filter { start, _, _, _ in start >= bounds.start && start < bounds.end }
            .map { start, title, category, apps in
            DaySlotSummary(
                slotStartMs: start,
                slotEndMs: start + slot,
                // Untitled rows carry their reason in the category slot, so the
                // lab shows every badge the panel can render, not just one.
                state: title == nil ? category : "done",
                anchorMomentId: "mock-\(abs(start / slot) % 12)",
                facts: DaySlotFacts(apps: apps, momentCount: 12),
                title: title,
                bullets: title.map { ["\($0)"] },
                category: title == nil ? nil : category
            )
        }
        return DaySummary(
            day: DaySummaryLayout.localDayKey(ms: playheadMs),
            dayStartMs: bounds.start,
            dayEndMs: bounds.end,
            slots: slots
        )
    }

    static func mockFactsOnly(around playheadMs: Int64) -> DaySummary {
        let rich = mockRich(around: playheadMs)
        let slots = rich.slots.map { row in
            DaySlotSummary(
                slotStartMs: row.slotStartMs,
                slotEndMs: row.slotEndMs,
                state: "degraded",
                facts: row.facts,
                title: nil,
                bullets: nil,
                category: nil
            )
        }
        return DaySummary(day: rich.day, dayStartMs: rich.dayStartMs, dayEndMs: rich.dayEndMs, slots: Array(slots.prefix(4)))
    }
}

/// A search result set spread across minutes, hours, days, and weeks, so the
/// filmstrip's relative stamps and the highlight blink can be judged in the
/// Visual Lab without a daemon or a real vault.
public enum MockSearchData {
    public static let query = "Moment"

    /// The title and one body line of frame 0, for surfaces that want a couple
    /// of boxes rather than a whole screen of them.
    public static let titleRegion = MockScreenText.regions(index: 0)[0]
    public static let bodyRegion = MockScreenText.regions(index: 0)[1]

    /// Ages chosen to exercise every branch of `RelativeStamp.short`.
    private static let agesMs: [Int64] = [
        20_000, 90_000, 7 * 60_000, 41 * 60_000,
        2 * 3_600_000, 9 * 3_600_000, 20 * 3_600_000,
        26 * 3_600_000, 3 * 86_400_000, 6 * 86_400_000,
        9 * 86_400_000, 25 * 86_400_000,
    ]

    private static let windows: [(app: String, bundle: String, title: String)] = [
        ("Figma", "com.figma.Desktop", "Recall — search presentation"),
        ("Safari", "com.apple.Safari", "Moment pipeline notes"),
        ("Xcode", "com.apple.dt.Xcode", "RecallView.swift — AfterRay"),
        ("Slack", "com.tinyspeck.slackmacgap", "#design · moment review"),
    ]

    public static var moments: [RecallMoment] {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return agesMs.enumerated()
            .map { index, age in
                let window = windows[index % windows.count]
                return RecallMoment(
                    id: "moment-\(index)",
                    sessionId: "session-search",
                    capturedAtMs: now - age,
                    imageArtifactId: "mock://frame/\(index)",
                    isFavorite: false,
                    ocrText: "Moment \(String(format: "%02d", index + 1)) · capture pipeline",
                    applicationName: window.app,
                    bundleIdentifier: window.bundle,
                    windowTitle: window.title
                )
            }
            .sorted { $0.capturedAtMs < $1.capturedAtMs }
    }

    public static var session: RecallSearchSession? {
        let hits = moments.enumerated().flatMap { index, moment -> [RecallSearchHit] in
            var hits = [
                RecallSearchHit(
                    momentId: moment.id,
                    sessionId: moment.sessionId,
                    capturedAtMs: moment.capturedAtMs,
                    source: "ocr",
                    text: moment.ocrText ?? "",
                    score: 1 - Double(index) * 0.01
                )
            ]
            // Some frames match twice, so the counter shows more hits than
            // frames — the case the tally label exists for.
            if index.isMultiple(of: 3) {
                hits.append(
                    RecallSearchHit(
                        momentId: moment.id,
                        sessionId: moment.sessionId,
                        capturedAtMs: moment.capturedAtMs,
                        source: "window",
                        text: moment.windowTitle ?? "",
                        score: 0.5
                    )
                )
            }
            return hits
        }
        return RecallSearchSession.make(query: query, hits: hits)
    }

    public static let thumbnailLoader: RecallThumbnailLoader = { momentID in
        let index = Int(momentID.split(separator: "-").last ?? "0") ?? 0
        return try await Task.detached(priority: .utility) {
            try MockArtifactFactory.renderFrame(index: index)
        }.value
    }

    /// Same pixels as the filmstrip mock — already 1280px — plus a fixture
    /// moment so citation cards can show a real captured-at stamp in labs.
    public static let previewLoader: RecallChatPreviewLoader = thumbnailLoader

    public static let momentLoader: RecallMomentLoader = { momentID in
        if let match = RecallScenario.long.moments.first(where: { $0.id == momentID }) {
            return match
        }
        let index = Int(momentID.split(separator: "-").last ?? "0") ?? 0
        return RecallMoment(
            id: momentID,
            sessionId: "session-today",
            capturedAtMs: RecallScenario.baseMs + Int64(index * 42_000),
            imageArtifactId: "mock://frame/\(index)",
            applicationName: "Xcode"
        )
    }

    public static let ocrLoader: RecallOcrLoader = { momentID in
        let index = Int(momentID.split(separator: "-").last ?? "0") ?? 0
        let regions = MockScreenText.regions(index: index)
        return OcrEvidence(
            momentId: momentID,
            text: regions.map(\.text).joined(separator: "\n"),
            regions: regions
        )
    }
}

/// The text a mock frame actually carries, and the OCR boxes that describe it.
///
/// Drawing and recognition read the same table and measure with the same font,
/// which is the only reason the transparent text layer lands on the glyphs in
/// the Visual Lab. Hand-written box coordinates drift away from the drawing the
/// first time either one is edited.
public enum MockScreenText {
    public struct Line: Sendable {
        public let text: String
        /// Fractions of the frame with the origin at the bottom left — Vision's
        /// convention, and the one an unflipped AppKit context draws in.
        public let x: Double
        public let y: Double
        /// Point size as a fraction of the frame width.
        public let size: Double
        public let weight: NSFont.Weight
    }

    public static let imageSize = NSSize(width: 1_280, height: 800)

    public static func lines(index: Int) -> [Line] {
        [
            Line(
                text: "Moment \(String(format: "%02d", index + 1))",
                x: 0.0935,
                y: 0.67,
                size: 0.042,
                weight: .semibold
            ),
            Line(
                text: "capture pipeline · shim → daemon → vault",
                x: 0.0935,
                y: 0.435,
                size: 0.020,
                weight: .regular
            ),
            Line(
                text: "OCR regions arrive as Vision unit-square boxes",
                x: 0.0935,
                y: 0.380,
                size: 0.020,
                weight: .regular
            ),
            // Mixed scripts on one line: word segmentation and the caret math
            // both behave differently here than on the Latin rows above.
            Line(
                text: "拖动即可选中这一帧上的文字，⌘C 复制",
                x: 0.0935,
                y: 0.325,
                size: 0.020,
                weight: .regular
            ),
        ]
    }

    public static func regions(index: Int) -> [OcrRegion] {
        lines(index: index).map { line in
            let measured = (line.text as NSString).size(withAttributes: attributes(for: line))
            return OcrRegion(
                text: line.text,
                confidence: 0.94,
                x: line.x,
                y: line.y,
                width: Double(measured.width) / Double(imageSize.width),
                height: Double(measured.height) / Double(imageSize.height)
            )
        }
    }

    /// Draws into the currently focused context, which the caller has set up at
    /// `imageSize` with the default bottom-left origin.
    public static func draw(index: Int) {
        for line in lines(index: index) {
            line.text.draw(
                at: NSPoint(x: line.x * imageSize.width, y: line.y * imageSize.height),
                withAttributes: attributes(for: line)
            )
        }
    }

    private static func attributes(for line: Line) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: line.size * imageSize.width, weight: line.weight),
            .foregroundColor: NSColor.white.withAlphaComponent(line.weight == .semibold ? 1 : 0.86),
        ]
    }
}

public enum MockArtifactFactory {
    public static let loader: RecallImageLoader = { artifactID in
        let index: Int
        if artifactID.hasPrefix("gop:") || artifactID.hasPrefix("gop-poster:") {
            let body = artifactID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let parts = body.split(separator: "#", maxSplits: 1)
            let segment = Int(parts.first?.split(separator: "-").last ?? "0") ?? 0
            let frame = Int(parts.count == 2 ? parts[1] : "0") ?? 0
            index = segment * 12 + frame
        } else {
            index = Int(artifactID.split(separator: "/").last ?? "0") ?? 0
        }
        return try await Task.detached(priority: .utility) {
            try renderFrame(index: index)
        }.value
    }

    public static func renderFrame(index: Int) throws -> Data {
        let size = MockScreenText.imageSize
        let image = NSImage(size: size)
        image.lockFocus()

        let palettes: [(NSColor, NSColor)] = [
            (.init(red: 0.18, green: 0.05, blue: 0.08, alpha: 1), .init(red: 0.94, green: 0.16, blue: 0.12, alpha: 1)),
            (.init(red: 0.04, green: 0.08, blue: 0.13, alpha: 1), .init(red: 0.16, green: 0.46, blue: 0.78, alpha: 1)),
            (.init(red: 0.07, green: 0.11, blue: 0.08, alpha: 1), .init(red: 0.32, green: 0.68, blue: 0.42, alpha: 1)),
            (.init(red: 0.12, green: 0.07, blue: 0.15, alpha: 1), .init(red: 0.65, green: 0.28, blue: 0.76, alpha: 1)),
        ]
        let palette = palettes[index % palettes.count]
        NSGradient(starting: palette.0, ending: NSColor.black)?.draw(in: NSRect(origin: .zero, size: size), angle: -24)

        let inset = size.width * 0.055
        let panel = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2), xRadius: 18, yRadius: 18)
        NSColor.white.withAlphaComponent(0.075).setFill()
        panel.fill()

        palette.1.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset * 1.7, y: size.height * 0.52, width: size.width * 0.24, height: max(5, size.height * 0.018)), xRadius: 4, yRadius: 4).fill()

        // Real strings rather than grey placeholder bars: the selectable text
        // layer can only be judged against glyphs it is actually drawn over.
        MockScreenText.draw(index: index)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw CocoaError(.fileWriteUnknown) }
        return jpeg
    }
}
