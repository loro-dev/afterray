/// How a snapshot's `tree_text` envelope carries its tree
/// (docs/event-capture-v2-plan.md §4).
package enum CaptureTreeTextMode: String, Sendable {
    /// The whole tree, and the base of a new diff chain.
    case fullTree
    /// A `TreeDiff` against the previous emission of the same chain.
    case diffFromPrevious
    /// The tree did not move. No text: the previous emission of this chain is
    /// still current. Spelled out rather than omitted so a reader can tell a
    /// static screen from a shim too old to encode trees at all.
    case unchanged
}

/// The `tree_text` field of an accessibility snapshot.
///
/// `chain` and `sequence` are beyond the plan's `{mode, text}` and exist because
/// the chains are per window: a `diffFromPrevious` is taken against the previous
/// emission *of its own chain*, which is not in general the previous artifact in
/// time. Without the pair a consumer cannot name the base, and a diff whose base
/// cannot be named is not decodable at all.
package struct CaptureTreeTextEnvelope: Equatable, Sendable {
    package let mode: CaptureTreeTextMode
    /// The rendered tree or diff; `nil` exactly when `mode` is `.unchanged`.
    package let text: String?
    /// Opaque identity of the diff chain, unique within one shim process.
    package let chain: String
    /// Position in the chain. A `diffFromPrevious` at `sequence` n decodes
    /// against the emission at n-1; an `.unchanged` reports the sequence that is
    /// still current and emits nothing new.
    package let sequence: Int
}

/// What identifies a diff chain.
///
/// The window is the obvious half. The walk root is the other: the heartbeat
/// walks the application element and an attached-tree walk starts at one window,
/// so the two produce trees with different roots for the same window. Diffing
/// across them would align an `AXApplication` against an `AXWindow` — "remove
/// everything, add everything", larger than the keyframe it replaced. Separate
/// chains keep each honest.
package struct CaptureTreeScope: Hashable, Sendable {
    package enum Walk: String, Hashable, Sendable {
        /// The heartbeat's whole-application walk.
        case application
        /// A single window, as an event-attached walk takes it.
        case window
    }

    package var processId: Int32
    package var windowTitle: String?
    package var walk: Walk

    package init(processId: Int32, windowTitle: String?, walk: Walk) {
        self.processId = processId
        self.windowTitle = windowTitle
        self.walk = walk
    }
}

/// One chain's state: the tree a consumer can reconstruct, and where it is.
private struct CaptureTreeChain {
    var id: String
    /// The last tree actually *emitted* — always what a consumer holds, which
    /// is why nothing is staged into it that the caller then fails to emit.
    var base: RenderedTree
    var fingerprint: UInt64
    var chainLength: Int
    var sequence: Int
}

/// A decided-but-not-yet-emitted envelope.
///
/// Staging is split from committing because emission can still fail after the
/// decision: the foreground can move between the walk and the write, and the
/// screenshot path deletes an accessibility artifact whose frame it could not
/// pair. A chain that advanced past an artifact nobody received would hand the
/// consumer a diff against a tree it never saw — silently, and for the rest of
/// the chain.
package struct StagedCaptureTreeText {
    package let envelope: CaptureTreeTextEnvelope
    fileprivate let scope: CaptureTreeScope
    /// The chain state to install, or `nil` when the decision changes nothing.
    fileprivate let chain: CaptureTreeChain?
}

/// Per-window diff chains over rendered AX trees.
///
/// Measured, a full tree is ~200 KB and the diff between two consecutive ones
/// has a 913 B median, so what a chain is worth is the difference between
/// storing every walk whole and storing it once. `KeyframePolicy` owns *when* a
/// chain re-bases; this owns *which* chain a walk belongs to and what the
/// consumer can reconstruct from it.
package struct CaptureTreeChains {
    /// Chains kept alive at once, evicted least-recently-used.
    ///
    /// Each holds a whole rendered tree — up to the encoder's 20k nodes — so
    /// this is a memory bound on a helper that runs all day, not a policy: six
    /// covers alternating between a few windows (and counts the heartbeat and
    /// window walks of one window separately), and an evicted chain costs one
    /// keyframe when its window comes back.
    package static let maxChains = 6

    private var chains: [CaptureTreeScope: CaptureTreeChain] = [:]
    /// Least-recently-used first.
    private var order: [CaptureTreeScope] = []
    private let processTag: String
    private var nextChainNumber = 0

    /// - Parameter processTag: anything unique to this shim process. Chain ids
    ///   are only meaningful while the shim lives — chains are in-memory — and
    ///   the tag keeps ids from two runs of the shim apart in a consumer that
    ///   sees both.
    package init(processTag: String) {
        self.processTag = processTag
    }

    /// Decides what this walk emits, without changing any chain.
    package mutating func stage(scope: CaptureTreeScope, tree: CaptureTreeNode) -> StagedCaptureTreeText {
        let rendered = CaptureTreeText.render(tree)
        let text = rendered.text
        let fingerprint = CaptureTreeFingerprint.of(text)
        let existing = chains[scope]

        let decision = KeyframePolicy.decide(
            // A scope with no chain has no base at all, which is exactly the
            // condition a window change creates.
            windowChanged: existing == nil,
            diffChainLength: existing?.chainLength ?? 0,
            fingerprintChanged: existing.map { $0.fingerprint != fingerprint } ?? true
        )

        switch decision {
        case .keyframe:
            let id = existing?.id ?? nextId()
            let sequence = existing.map { $0.sequence + 1 } ?? 0
            return StagedCaptureTreeText(
                envelope: CaptureTreeTextEnvelope(
                    mode: .fullTree,
                    text: text,
                    chain: id,
                    sequence: sequence
                ),
                scope: scope,
                chain: CaptureTreeChain(
                    id: id,
                    base: rendered,
                    fingerprint: fingerprint,
                    chainLength: 0,
                    sequence: sequence
                )
            )
        case .diff:
            guard let existing else { return unchanged(scope: scope, chain: nil) }
            let diff = TreeDiff.between(previous: existing.base, current: rendered)
            guard !diff.isEmpty else {
                // The text moved but the alignment found nothing: only the
                // numbering shifted (two identical siblings swapped, say). The
                // base stays, because the base is defined as what the consumer
                // can reconstruct and an empty diff reconstructs the old tree.
                // The fingerprint advances so the same walk does not pay for a
                // second alignment.
                var stilled = existing
                stilled.fingerprint = fingerprint
                return unchanged(scope: scope, chain: stilled)
            }
            let sequence = existing.sequence + 1
            return StagedCaptureTreeText(
                envelope: CaptureTreeTextEnvelope(
                    mode: .diffFromPrevious,
                    text: diff.text,
                    chain: existing.id,
                    sequence: sequence
                ),
                scope: scope,
                chain: CaptureTreeChain(
                    id: existing.id,
                    base: rendered,
                    fingerprint: fingerprint,
                    chainLength: KeyframePolicy.chainLength(after: .diff, previous: existing.chainLength),
                    sequence: sequence
                )
            )
        case .skip:
            return unchanged(scope: scope, chain: nil)
        }
    }

    /// Installs a staged decision. Called only once the artifact carrying it is
    /// on its way to the daemon.
    package mutating func commit(_ staged: StagedCaptureTreeText) {
        if let chain = staged.chain {
            chains[staged.scope] = chain
        }
        touch(staged.scope)
        evictIfNeeded()
    }

    /// Chains currently held — for tests and logging.
    package var chainCount: Int { chains.count }

    private func envelopeForUnchanged(scope: CaptureTreeScope) -> CaptureTreeTextEnvelope {
        let existing = chains[scope]
        return CaptureTreeTextEnvelope(
            mode: .unchanged,
            text: nil,
            chain: existing?.id ?? "",
            sequence: existing?.sequence ?? 0
        )
    }

    private func unchanged(scope: CaptureTreeScope, chain: CaptureTreeChain?) -> StagedCaptureTreeText {
        StagedCaptureTreeText(
            envelope: envelopeForUnchanged(scope: scope),
            scope: scope,
            chain: chain
        )
    }

    private mutating func nextId() -> String {
        nextChainNumber += 1
        return "\(processTag)-\(nextChainNumber)"
    }

    private mutating func touch(_ scope: CaptureTreeScope) {
        guard chains[scope] != nil else { return }
        order.removeAll { $0 == scope }
        order.append(scope)
    }

    private mutating func evictIfNeeded() {
        while order.count > Self.maxChains {
            let evicted = order.removeFirst()
            chains.removeValue(forKey: evicted)
        }
    }
}

/// A cheap, stable hash of a rendered tree — the plan's `digest_fingerprint`
/// stillness check.
///
/// FNV-1a, not a cryptographic digest: the question is only "is this the same
/// text I emitted last time", a collision costs one skipped snapshot of a screen
/// that did move, and this runs over ~200 KB on every walk.
package enum CaptureTreeFingerprint {
    package static func of(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
