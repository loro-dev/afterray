import AfterRayRecall
import AppKit
import Foundation

public enum RecallScenario: String, CaseIterable, Identifiable, Sendable {
    case empty
    case short
    case long
    case processing
    case favorites
    case search

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .empty: "Empty"
        case .short: "Short"
        case .long: "Long day"
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
        case .long, .processing, .favorites, .search:
            return .mockRich(around: Self.baseMs)
        }
    }

    static let baseMs: Int64 = 1_786_483_800_000

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
        let applications = [
            ("Figma", "com.figma.Desktop"),
            ("Safari", "com.apple.Safari"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Notion", "notion.id"),
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
                applicationName: app.0,
                bundleIdentifier: app.1
            )
        }
    }
}

public extension DaySummary {
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

    /// Where `MockArtifactFactory` draws the frame title, in Vision's
    /// bottom-left-origin unit square. Keeping this next to the drawing code is
    /// what makes the overlay land on the actual glyphs.
    public static let titleRegion = OcrRegion(
        text: "Moment",
        confidence: 0.96,
        x: 0.093,
        y: 0.664,
        width: 0.209,
        height: 0.068
    )
    public static let bodyRegion = OcrRegion(
        text: "capture pipeline",
        confidence: 0.81,
        x: 0.093,
        y: 0.366,
        width: 0.520,
        height: 0.014
    )

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
        return try MockArtifactFactory.renderFrame(index: index)
    }

    public static let ocrLoader: RecallOcrLoader = { momentID in
        OcrEvidence(
            momentId: momentID,
            text: "Moment · capture pipeline",
            regions: [titleRegion, bodyRegion]
        )
    }
}

public enum MockArtifactFactory {
    public static let loader: RecallImageLoader = { artifactID in
        let index = Int(artifactID.split(separator: "/").last ?? "0") ?? 0
        return try renderFrame(index: index)
    }

    public static func renderFrame(index: Int) throws -> Data {
        let size = NSSize(width: 1_280, height: 800)
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

        let title = "Moment \(String(format: "%02d", index + 1))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.042, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        title.draw(at: NSPoint(x: inset * 1.7, y: size.height * 0.67), withAttributes: attributes)

        palette.1.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset * 1.7, y: size.height * 0.52, width: size.width * 0.24, height: max(5, size.height * 0.018)), xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.16).setFill()
        for row in 0..<3 {
            NSBezierPath(roundedRect: NSRect(x: inset * 1.7, y: size.height * (0.37 - Double(row) * 0.075), width: size.width * (0.52 - Double(row) * 0.08), height: max(4, size.height * 0.013)), xRadius: 3, yRadius: 3).fill()
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw CocoaError(.fileWriteUnknown) }
        return jpeg
    }
}
