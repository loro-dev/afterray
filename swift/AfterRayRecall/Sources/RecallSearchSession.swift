import Foundation

/// One captured frame that a query matched, with every piece of evidence that
/// pointed at it.
///
/// The daemon ranks loose evidence rows, so a single frame can arrive several
/// times over — OCR text and a window title and a transcript line. The
/// filmstrip navigates *frames*, so they are folded here.
public struct SearchFrame: Identifiable, Equatable, Sendable {
    public let momentId: String
    public let capturedAtMs: Int64
    public let hits: [RecallSearchHit]

    public var id: String { momentId }

    public init(momentId: String, capturedAtMs: Int64, hits: [RecallSearchHit]) {
        self.momentId = momentId
        self.capturedAtMs = capturedAtMs
        self.hits = hits
    }

    /// Evidence text to show for this frame: the highest-scoring hit.
    public var excerpt: String {
        hits.max { $0.score < $1.score }?.text ?? ""
    }

    /// `ocr`, `transcript`, or `window` — whichever hit ranked highest.
    public var primarySource: String {
        hits.max { $0.score < $1.score }?.source ?? "ocr"
    }
}

/// The result set behind one submitted query.
///
/// Ordering is newest first, deliberately: recall almost always means "the
/// thing I was just looking at", so the freshest match is the useful default.
public struct RecallSearchSession: Equatable, Sendable {
    public let query: String
    public let frames: [SearchFrame]
    public let totalHits: Int
    public var selectedIndex: Int

    public init(query: String, frames: [SearchFrame], totalHits: Int, selectedIndex: Int = 0) {
        self.query = query
        self.frames = frames
        self.totalHits = totalHits
        self.selectedIndex = min(max(selectedIndex, 0), max(frames.count - 1, 0))
    }

    /// Folds ranked evidence into frames. Returns `nil` when nothing usable
    /// came back, so callers can treat "no session" and "no results" alike.
    public static func make(query: String, hits: [RecallSearchHit]) -> RecallSearchSession? {
        // The daemon yields an empty moment id when no frame precedes a
        // transcript line. Those cannot be opened, so they are not results.
        let usable = hits.filter { !$0.momentId.isEmpty }
        guard !usable.isEmpty else { return nil }

        var order: [String] = []
        var grouped: [String: [RecallSearchHit]] = [:]
        for hit in usable {
            if grouped[hit.momentId] == nil { order.append(hit.momentId) }
            grouped[hit.momentId, default: []].append(hit)
        }

        let frames = order.compactMap { momentId -> SearchFrame? in
            guard let hits = grouped[momentId], let first = hits.first else { return nil }
            return SearchFrame(
                momentId: momentId,
                capturedAtMs: first.capturedAtMs,
                hits: hits.sorted { $0.score > $1.score }
            )
        }
        .sorted { left, right in
            if left.capturedAtMs == right.capturedAtMs { return left.momentId < right.momentId }
            return left.capturedAtMs > right.capturedAtMs
        }

        return RecallSearchSession(
            query: query,
            frames: frames,
            totalHits: usable.count,
            selectedIndex: 0
        )
    }

    public var selectedFrame: SearchFrame? {
        guard frames.indices.contains(selectedIndex) else { return nil }
        return frames[selectedIndex]
    }

    /// Clamped rather than wrapping: at the newest result, pressing "previous"
    /// should feel like hitting a wall, not teleporting a week backwards.
    public func steppedIndex(by delta: Int) -> Int {
        guard !frames.isEmpty else { return 0 }
        return min(max(selectedIndex + delta, 0), frames.count - 1)
    }

    public func index(ofMomentID momentID: String) -> Int? {
        frames.firstIndex { $0.momentId == momentID }
    }

    /// "2/24" — position within the frames the filmstrip shows.
    public var positionLabel: String {
        "\(selectedIndex + 1)/\(frames.count)"
    }

    /// "31 matches · 24 frames", or the singular forms.
    public var tallyLabel: String {
        let matches = totalHits == 1 ? "1 match" : "\(totalHits) matches"
        let frameCount = frames.count == 1 ? "1 frame" : "\(frames.count) frames"
        return "\(matches) · \(frameCount)"
    }
}
