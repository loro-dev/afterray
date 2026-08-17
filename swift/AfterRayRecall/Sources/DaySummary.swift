import Foundation

public struct DayAppFact: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let ms: Int64

    public init(name: String, bundleIdentifier: String? = nil, ms: Int64) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.ms = ms
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier = "bundle_identifier"
        case ms
    }
}

public struct DaySlotFacts: Codable, Equatable, Sendable {
    public let apps: [DayAppFact]
    public let momentCount: Int

    public init(apps: [DayAppFact], momentCount: Int = 0) {
        self.apps = apps
        self.momentCount = momentCount
    }

    enum CodingKeys: String, CodingKey {
        case apps
        case momentCount = "moment_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([DayAppFact].self, forKey: .apps) ?? []
        momentCount = try container.decodeIfPresent(Int.self, forKey: .momentCount) ?? 0
    }
}

public struct DaySlotSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64 { slotStartMs }
    public let slotStartMs: Int64
    public let slotEndMs: Int64
    public let state: String
    /// First captured frame of the slot; the row's thumbnail anchor.
    public let anchorMomentId: String?
    public let facts: DaySlotFacts
    public let title: String?
    public let bullets: [String]?
    public let category: String?
    public let description: String?
    public let threads: [SummaryThread]?
    public let entities: [SummaryEntity]?
    public let decisions: [String]?
    public let notCaptured: [String]?

    public init(
        slotStartMs: Int64,
        slotEndMs: Int64,
        state: String,
        anchorMomentId: String? = nil,
        facts: DaySlotFacts,
        title: String? = nil,
        bullets: [String]? = nil,
        category: String? = nil,
        description: String? = nil,
        threads: [SummaryThread]? = nil,
        entities: [SummaryEntity]? = nil,
        decisions: [String]? = nil,
        notCaptured: [String]? = nil
    ) {
        self.slotStartMs = slotStartMs
        self.slotEndMs = slotEndMs
        self.state = state
        self.anchorMomentId = anchorMomentId
        self.facts = facts
        self.title = title
        self.bullets = bullets
        self.category = category
        self.description = description
        self.threads = threads
        self.entities = entities
        self.decisions = decisions
        self.notCaptured = notCaptured
    }

    enum CodingKeys: String, CodingKey {
        case slotStartMs = "slot_start_ms"
        case slotEndMs = "slot_end_ms"
        case state
        case anchorMomentId = "anchor_moment_id"
        case facts
        case title
        case bullets
        case category
        case description, threads, entities, decisions
        case notCaptured = "not_captured"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slotStartMs = try container.decode(Int64.self, forKey: .slotStartMs)
        slotEndMs = try container.decode(Int64.self, forKey: .slotEndMs)
        state = try container.decode(String.self, forKey: .state)
        anchorMomentId = try container.decodeIfPresent(String.self, forKey: .anchorMomentId)
        facts = try container.decodeIfPresent(DaySlotFacts.self, forKey: .facts)
            ?? DaySlotFacts(apps: [])
        title = try container.decodeIfPresent(String.self, forKey: .title)
        bullets = try container.decodeIfPresent([String].self, forKey: .bullets)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        threads = try container.decodeIfPresent([SummaryThread].self, forKey: .threads)
        entities = try container.decodeIfPresent([SummaryEntity].self, forKey: .entities)
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions)
        notCaptured = try container.decodeIfPresent([String].self, forKey: .notCaptured)
    }
}

public struct DaySummary: Codable, Equatable, Sendable {
    public let day: String
    public let dayStartMs: Int64
    public let dayEndMs: Int64
    public let slots: [DaySlotSummary]

    public static let empty = DaySummary(day: "", dayStartMs: 0, dayEndMs: 0, slots: [])

    public init(day: String, dayStartMs: Int64, dayEndMs: Int64, slots: [DaySlotSummary]) {
        self.day = day
        self.dayStartMs = dayStartMs
        self.dayEndMs = dayEndMs
        self.slots = slots
    }

    public var isEmpty: Bool { slots.isEmpty }

    enum CodingKeys: String, CodingKey {
        case day
        case dayStartMs = "day_start_ms"
        case dayEndMs = "day_end_ms"
        case slots
    }
}

/// A bounded, descending slice of the history-summary panel. The daemon owns
/// the cursor so the app never needs to enumerate the encrypted vault.
public struct SummaryHistoryPage: Codable, Equatable, Sendable {
    public let days: [DaySummary]
    public let nextBeforeMs: Int64?
    public let hasMore: Bool

    public init(days: [DaySummary], nextBeforeMs: Int64?, hasMore: Bool) {
        self.days = days
        self.nextBeforeMs = nextBeforeMs
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case days
        case nextBeforeMs = "next_before_ms"
        case hasMore = "has_more"
    }
}

public struct DaySummaryHeading: Equatable, Sendable {
    public let kicker: String
    public let title: String
    public let isToday: Bool
}

/// Plain-text renderings of summaries for the clipboard. The panel displays
/// newest-first, but copied text reads chronologically — pasted notes flow
/// forward in time the way prose does.
public enum DaySummaryClipboard {
    public static func slotText(_ slot: DaySlotSummary, timeZone: TimeZone = .current) -> String {
        let text = DaySummaryLayout.rowText(slot: slot, timeZone: timeZone)
        var lines = ["\(text.time) \(text.primary)"]
        let expanded = DaySummaryLayout.expandedSections(slot: slot)
        if expanded.isEmpty {
            for detail in text.detail {
                lines.append("  - \(detail)")
            }
        } else {
            for section in expanded {
                if let heading = section.heading {
                    lines.append("  \(heading): \(section.body)")
                } else {
                    lines.append("  - \(section.body)")
                }
            }
        }
        if let badge = text.badge {
            lines.append("  (\(badge))")
        }
        return lines.joined(separator: "\n")
    }

    public static func dayText(_ summary: DaySummary, timeZone: TimeZone = .current) -> String {
        var lines = ["## \(summary.day)"]
        for slot in summary.slots
            .filter(DaySummaryLayout.isVisibleInPanel)
            .sorted(by: { $0.slotStartMs < $1.slotStartMs })
        {
            lines.append(slotText(slot, timeZone: timeZone))
        }
        return lines.joined(separator: "\n")
    }

    /// Every loaded day, oldest first, blank line between days.
    public static func historyText(_ summaries: [DaySummary], timeZone: TimeZone = .current) -> String {
        summaries
            .sorted { $0.dayStartMs < $1.dayStartMs }
            .map { dayText($0, timeZone: timeZone) }
            .joined(separator: "\n\n")
    }
}

public struct DaySummaryRowText: Equatable, Sendable {
    public let time: String
    public let primary: String
    /// The written summary under the title. The panel is the only place a
    /// slot's card is ever read, so it carries the whole body — a
    /// truncated one sends the user back to the timeline to guess.
    public let detail: [String]
    public let isT2: Bool
    /// Why this row is showing raw activity instead of a summary. Nil once a
    /// model has written a card. Without it a fallback row reads as if the
    /// slot genuinely amounted to "Zed 6m · Chrome 3m", when in fact
    /// nothing has looked at it yet.
    public let badge: String?

    public init(
        time: String,
        primary: String,
        detail: [String] = [],
        isT2: Bool,
        badge: String? = nil
    ) {
        self.time = time
        self.primary = primary
        self.detail = detail
        self.isT2 = isT2
        self.badge = badge
    }
}

public struct DaySummaryExpandedSection: Equatable, Sendable {
    public let heading: String?
    public let body: String
}

/// Slot grouping, highlight, and row copy — kept pure so Visual Lab and
/// production share one implementation and the tests can pin the wording.
public enum DaySummaryLayout {
    public static let slotDurationMs: Int64 = 10 * 60 * 1_000
    public static let expandedStorageKey = "dev.afterray.daySummaryExpanded"

    public static func localDayKey(ms: Int64, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    public static func dayBounds(ms: Int64, timeZone: TimeZone = .current) -> (start: Int64, end: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (
            Int64(start.timeIntervalSince1970 * 1_000),
            Int64(end.timeIntervalSince1970 * 1_000)
        )
    }

    public static func slotStartMs(atMs: Int64, timeZone: TimeZone = .current) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(atMs) / 1_000)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        parts.minute = (minute / 10) * 10
        parts.second = 0
        parts.nanosecond = 0
        let aligned = calendar.date(from: parts) ?? date
        return Int64((aligned.timeIntervalSince1970 * 1_000).rounded())
    }

    public static func highlightedSlotStartMs(
        playheadMs: Int64,
        slots: [DaySlotSummary],
        timeZone: TimeZone = .current
    ) -> Int64? {
        // Only consider rows the panel actually draws, so scrubbing through
        // an idle gap does not try to follow a card that was never rendered.
        let visible = slots.filter(isVisibleInPanel)
        if let covering = visible.first(where: { $0.slotStartMs <= playheadMs && playheadMs < $0.slotEndMs }) {
            return covering.slotStartMs
        }
        let start = slotStartMs(atMs: playheadMs, timeZone: timeZone)
        return visible.contains(where: { $0.slotStartMs == start }) ? start : nil
    }

    /// Idle half-hours carry no activity worth reading; the summary panel
    /// omits them so the feed is only real work. Gaps still show on the
    /// timeline. Storage and the wire keep the full slot list.
    public static func isVisibleInPanel(_ slot: DaySlotSummary) -> Bool {
        slot.state != "skipped_idle"
    }

    /// Panel display order: newest slot first, matching how every feed
    /// the user lives in orders time. Storage and the chat tool keep
    /// chronological order; this is presentation only. Idle slots are
    /// dropped here rather than in the store so mock data and copy still
    /// see the underlying day as the daemon sent it.
    public static func displayOrder(_ slots: [DaySlotSummary]) -> [DaySlotSummary] {
        slots
            .filter(isVisibleInPanel)
            .sorted { $0.slotStartMs > $1.slotStartMs }
    }

    public static func timeLabel(slotStartMs: Int64, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(slotStartMs) / 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func dateHeading(
        dayStartMs: Int64,
        nowMs: Int64,
        timeZone: TimeZone = .current
    ) -> DaySummaryHeading {
        if dayStartMs == 0 {
            return DaySummaryHeading(kicker: "TODAY", title: "No day selected", isToday: true)
        }
        let isToday = localDayKey(ms: dayStartMs, timeZone: timeZone)
            == localDayKey(ms: nowMs, timeZone: timeZone)
        let date = Date(timeIntervalSince1970: TimeInterval(dayStartMs) / 1_000)
        let weekday = date.formatted(
            Date.FormatStyle().weekday(.abbreviated).locale(Locale(identifier: "en_US_POSIX"))
        )
        let monthDay = date.formatted(
            Date.FormatStyle().month(.abbreviated).day().locale(Locale(identifier: "en_US_POSIX"))
        )
        if isToday {
            return DaySummaryHeading(kicker: "TODAY", title: monthDay, isToday: true)
        }
        return DaySummaryHeading(kicker: weekday.uppercased(), title: monthDay, isToday: false)
    }

    public static func formatDuration(ms: Int64) -> String {
        let minutes = max(Int((Double(ms) / 60_000).rounded()), 0)
        if minutes == 0 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remain = minutes % 60
        return remain == 0 ? "\(hours)h" : "\(hours)h \(remain)m"
    }

    public static func factLine(apps: [DayAppFact]) -> String {
        let parts = apps.prefix(3).map { "\($0.name) \(formatDuration(ms: $0.ms))" }
        if parts.isEmpty { return "Quiet — nothing on screen" }
        return parts.joined(separator: " · ")
    }

    public static func rowText(slot: DaySlotSummary, timeZone: TimeZone = .current) -> DaySummaryRowText {
        let time = timeLabel(slotStartMs: slot.slotStartMs, timeZone: timeZone)
        if let title = slot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let description = shortDescription(slot: slot)
            return DaySummaryRowText(
                time: time,
                primary: title,
                detail: description.isEmpty ? [] : [description],
                isT2: true
            )
        }
        return DaySummaryRowText(
            time: time,
            primary: factLine(apps: slot.facts.apps),
            detail: [],
            isT2: false,
            badge: fallbackBadge(state: slot.state)
        )
    }


    public static func shortDescription(slot: DaySlotSummary) -> String {
        let source: String
        if let description = slot.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = description
        } else {
            source = (slot.bullets ?? []).joined(separator: " ")
        }
        return String(normalizedParagraph(source).prefix(400))
    }

    public static func expandedSections(slot: DaySlotSummary) -> [DaySummaryExpandedSection] {
        if let threads = slot.threads, !threads.isEmpty {
            var sections = threads.compactMap { thread -> DaySummaryExpandedSection? in
                let body = normalizedParagraph(thread.prose)
                guard !body.isEmpty else { return nil }
                let heading = normalizedParagraph(thread.name)
                return DaySummaryExpandedSection(heading: heading.isEmpty ? nil : heading, body: body)
            }
            if let decisions = slot.decisions?.filter({ !normalizedParagraph($0).isEmpty }), !decisions.isEmpty {
                sections.append(DaySummaryExpandedSection(
                    heading: "Decisions",
                    body: decisions.map(normalizedParagraph).joined(separator: "\n")
                ))
            }
            if let missing = slot.notCaptured?.filter({ !normalizedParagraph($0).isEmpty }), !missing.isEmpty {
                sections.append(DaySummaryExpandedSection(
                    heading: "Not captured",
                    body: missing.map(normalizedParagraph).joined(separator: "\n")
                ))
            }
            return sections
        }
        return (slot.bullets ?? []).compactMap { bullet in
            let body = normalizedParagraph(bullet)
            return body.isEmpty ? nil : DaySummaryExpandedSection(heading: nil, body: body)
        }
    }

    private static func normalizedParagraph(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Names the reason a row has no summary. "Not summarised" and "Summary
    /// failed" are different situations — one is waiting its turn, the other
    /// needs the model looked at — and a row that was deliberately skipped
    /// should not claim to be pending forever.
    static func fallbackBadge(state: String) -> String? {
        switch state {
        case "failed": "Summary failed"
        case "skipped_idle": "Idle"
        case "paused": "Capture paused"
        case "asleep": "Asleep"
        case "no_data": nil
        default: "Not summarised"
        }
    }
}
