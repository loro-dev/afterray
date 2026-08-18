/// What to do with the AX tree an event just triggered
/// (docs/event-capture-v2-plan.md §4).
package enum CaptureFrameDecision: Equatable, Sendable {
    /// The tree has not moved. Emit nothing.
    case skip
    /// Emit the whole tree. It also becomes the base of a new diff chain.
    case keyframe
    /// Emit `diffFromPrevious` against the last emitted tree.
    case diff
}

/// When a full tree is worth its size and when a diff will do.
///
/// Measured on the reference corpus: 130 of 140 full trees hung on
/// `window.changed`, and 120 of those came with an app switch. Nothing else
/// needed one. That is not a heuristic about size — a window switch invalidates
/// the diff *base*: the previous tree describes a different window, so a diff
/// against it would be "delete everything, add everything", larger than the
/// keyframe it was trying to avoid and unreadable besides.
///
/// Kept pure and apart from the shim because the failure modes are a silent
/// chain that never re-bases (one corrupt diff poisons every later frame) and a
/// keyframe on every event (~200 KB a click), and neither shows up in a test
/// that needs a live AX tree.
package enum KeyframePolicy {
    /// Longest run of diffs before a keyframe is forced.
    ///
    /// A diff chain is only as trustworthy as its base: each link is decoded
    /// against the one before it, so a reader who lost or mis-decoded one link
    /// has lost the rest of the chain, and a corrupted base is unrecoverable.
    /// Thirty caps that blast radius, and at the measured diff size the periodic
    /// keyframe costs about as much as the diffs it re-bases.
    package static let maxDiffChainLength = 30

    /// The decision for one triggering event.
    ///
    /// - Parameters:
    ///   - windowChanged: the walked window is not the one the last emitted
    ///     tree described.
    ///   - diffChainLength: diffs emitted since the last keyframe.
    ///   - fingerprintChanged: the tree's digest differs from the last emitted
    ///     tree's.
    ///
    /// A window change outranks the stillness check: the previous tree is no
    /// longer a valid base whatever the digest says, so "unchanged" cannot be
    /// concluded across it.
    package static func decide(
        windowChanged: Bool,
        diffChainLength: Int,
        fingerprintChanged: Bool
    ) -> CaptureFrameDecision {
        if windowChanged { return .keyframe }
        guard fingerprintChanged else { return .skip }
        if diffChainLength >= maxDiffChainLength { return .keyframe }
        return .diff
    }

    /// The chain length to carry into the next decision. A keyframe re-bases the
    /// chain, a diff extends it, and a skip — having emitted nothing — leaves it
    /// exactly where it was.
    package static func chainLength(after decision: CaptureFrameDecision, previous: Int) -> Int {
        switch decision {
        case .keyframe: return 0
        case .diff: return previous + 1
        case .skip: return previous
        }
    }
}
