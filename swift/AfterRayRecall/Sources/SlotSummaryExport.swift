import Foundation

public struct SummaryThread: Codable, Equatable, Sendable {
    public let name: String
    public let prose: String
    public let momentIds: [String]

    public init(name: String, prose: String, momentIds: [String] = []) {
        self.name = name
        self.prose = prose
        self.momentIds = momentIds
    }

    enum CodingKeys: String, CodingKey {
        case name, prose
        case momentIds = "moment_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        prose = try container.decode(String.self, forKey: .prose)
        // Rust omits an empty citation list. Older persisted v2 cards commonly
        // have no moment_ids key, which means "no citations", not a malformed
        // thread; requiring it makes one row poison the whole day response.
        momentIds = try container.decodeIfPresent([String].self, forKey: .momentIds) ?? []
    }
}

public struct SummaryEntity: Codable, Equatable, Sendable {
    public let text: String
    public let kind: String?
    public let momentId: String?

    public init(text: String, kind: String? = nil, momentId: String? = nil) {
        self.text = text
        self.kind = kind
        self.momentId = momentId
    }

    enum CodingKeys: String, CodingKey {
        case text, kind
        case momentId = "moment_id"
    }
}

/// The union of the three card shapes the vault can export. Which one a
/// payload is comes from `SlotSummaryExport.schemaVersion`, not from which
/// fields are nil: 1 is `bullets`, 2 is `threads`, 3 is `details`.
public struct SlotSummaryPayload: Codable, Equatable, Sendable {
    public let title: String
    public let description: String?
    /// The v3 card body, Markdown.
    public let details: String?
    public let threads: [SummaryThread]?
    public let entities: [SummaryEntity]?
    public let decisions: [String]?
    public let notCaptured: [String]?
    public let artifacts: [String]?
    public let bullets: [String]?
    public let category: String?
    public let confidence: Double?

    public init(
        title: String,
        description: String? = nil,
        details: String? = nil,
        threads: [SummaryThread]? = nil,
        entities: [SummaryEntity]? = nil,
        decisions: [String]? = nil,
        notCaptured: [String]? = nil,
        artifacts: [String]? = nil,
        bullets: [String]? = nil,
        category: String? = nil,
        confidence: Double? = nil
    ) {
        self.title = title
        self.description = description
        self.details = details
        self.threads = threads
        self.entities = entities
        self.decisions = decisions
        self.notCaptured = notCaptured
        self.artifacts = artifacts
        self.bullets = bullets
        self.category = category
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case title, description, details, threads, entities, decisions, artifacts, bullets
        case category, confidence
        case notCaptured = "not_captured"
    }
}

public struct SlotSummaryExport: Codable, Equatable, Sendable {
    public let slotStartMs: Int64
    public let slotEndMs: Int64
    public let state: String
    public let schemaVersion: Int64?
    public let summary: SlotSummaryPayload?
    public let facts: DaySlotFacts
    public let generation: Int64?
    public let producer: String?
    public let producedAtMs: Int64?
    public let latencyMs: Int64?

    public init(
        slotStartMs: Int64,
        slotEndMs: Int64,
        state: String,
        schemaVersion: Int64? = nil,
        summary: SlotSummaryPayload? = nil,
        facts: DaySlotFacts,
        generation: Int64? = nil,
        producer: String? = nil,
        producedAtMs: Int64? = nil,
        latencyMs: Int64? = nil
    ) {
        self.slotStartMs = slotStartMs
        self.slotEndMs = slotEndMs
        self.state = state
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.facts = facts
        self.generation = generation
        self.producer = producer
        self.producedAtMs = producedAtMs
        self.latencyMs = latencyMs
    }

    enum CodingKeys: String, CodingKey {
        case state, summary, facts, generation, producer
        case slotStartMs = "slot_start_ms"
        case slotEndMs = "slot_end_ms"
        case schemaVersion = "schema_version"
        case producedAtMs = "produced_at_ms"
        case latencyMs = "latency_ms"
    }
}
