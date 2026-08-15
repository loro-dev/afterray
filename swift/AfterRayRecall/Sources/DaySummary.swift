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
    public let facts: DaySlotFacts
    public let title: String?
    public let bullets: [String]?
    public let category: String?

    public init(
        slotStartMs: Int64,
        slotEndMs: Int64,
        state: String,
        facts: DaySlotFacts,
        title: String? = nil,
        bullets: [String]? = nil,
        category: String? = nil
    ) {
        self.slotStartMs = slotStartMs
        self.slotEndMs = slotEndMs
        self.state = state
        self.facts = facts
        self.title = title
        self.bullets = bullets
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case slotStartMs = "slot_start_ms"
        case slotEndMs = "slot_end_ms"
        case state
        case facts
        case title
        case bullets
        case category
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

public struct DaySummaryRowText: Equatable, Sendable {
    public let time: String
    public let primary: String
    /// The written summary under the title. The panel is the only place a
    /// half hour's card is ever read, so it carries the whole body — a
    /// truncated one sends the user back to the timeline to guess.
    public let detail: [String]
    public let isT2: Bool
    /// Why this row is showing raw activity instead of a summary. Nil once a
    /// model has written a card. Without it a fallback row reads as if the
    /// half hour genuinely amounted to "Zed 14m · Chrome 9m", when in fact
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

/// Slot grouping, highlight, and row copy — kept pure so Visual Lab and
/// production share one implementation and the tests can pin the wording.
public enum DaySummaryLayout {
    public static let slotDurationMs: Int64 = 30 * 60 * 1_000
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
        parts.minute = minute < 30 ? 0 : 30
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
        if let covering = slots.first(where: { $0.slotStartMs <= playheadMs && playheadMs < $0.slotEndMs }) {
            return covering.slotStartMs
        }
        let start = slotStartMs(atMs: playheadMs, timeZone: timeZone)
        return slots.contains(where: { $0.slotStartMs == start }) ? start : nil
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
        let detail = (slot.bullets ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let title = slot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return DaySummaryRowText(time: time, primary: title, detail: detail, isT2: true)
        }
        return DaySummaryRowText(
            time: time,
            primary: factLine(apps: slot.facts.apps),
            detail: detail,
            isT2: false,
            badge: fallbackBadge(state: slot.state)
        )
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
