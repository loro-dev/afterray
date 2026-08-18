@testable import AfterRayCapturePolicy
import XCTest

/// Per-window diff chains, from docs/event-capture-v2-plan.md §4.
final class TreeTextChainTests: XCTestCase {
    private func window(_ title: String, children: [CaptureTreeNode] = []) -> CaptureTreeNode {
        CaptureTreeNode(role: "AXWindow", subrole: "AXStandardWindow", title: title, children: children)
    }

    private func button(_ title: String) -> CaptureTreeNode {
        CaptureTreeNode(role: "AXButton", title: title)
    }

    private func scope(
        _ pid: Int32 = 501,
        _ title: String? = "Inbox",
        walk: CaptureTreeScope.Walk = .window
    ) -> CaptureTreeScope {
        CaptureTreeScope(processId: pid, windowTitle: title, walk: walk)
    }

    /// The first sight of a window has no base to diff against.
    func testAFirstWalkIsAFullTree() {
        var chains = CaptureTreeChains(processTag: "run")
        let staged = chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")]))
        XCTAssertEqual(staged.envelope.mode, .fullTree)
        XCTAssertEqual(staged.envelope.sequence, 0)
        XCTAssertTrue(staged.envelope.text?.contains("Send") ?? false)
    }

    func testASecondWalkOfTheSameWindowDiffsAgainstTheFirst() {
        var chains = CaptureTreeChains(processTag: "run")
        chains.commit(chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")])))
        let staged = chains.stage(
            scope: scope(),
            tree: window("Mail", children: [button("Send"), button("Archive")])
        )
        XCTAssertEqual(staged.envelope.mode, .diffFromPrevious)
        XCTAssertEqual(staged.envelope.sequence, 1, "the diff decodes against sequence 0")
        let text = staged.envelope.text ?? ""
        XCTAssertTrue(text.contains("Archive"), "the diff carries what arrived")
        XCTAssertFalse(text.contains("+0 standard window"), "the unchanged root is context, not an addition")
    }

    /// The whole point of the chain: a still screen costs nothing but a marker.
    func testAStillTreeIsUnchangedAndCarriesNoText() {
        var chains = CaptureTreeChains(processTag: "run")
        chains.commit(chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")])))
        let staged = chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")]))
        XCTAssertEqual(staged.envelope.mode, .unchanged)
        XCTAssertNil(staged.envelope.text)
        XCTAssertEqual(staged.envelope.sequence, 0, "sequence 0 is still the current tree")
    }

    /// An `.unchanged` emission is not a link: the next real change still diffs
    /// against the last tree the consumer actually received.
    func testAnUnchangedWalkDoesNotAdvanceTheChain() {
        var chains = CaptureTreeChains(processTag: "run")
        chains.commit(chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")])))
        chains.commit(chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")])))
        let staged = chains.stage(
            scope: scope(),
            tree: window("Mail", children: [button("Send"), button("Archive")])
        )
        XCTAssertEqual(staged.envelope.mode, .diffFromPrevious)
        XCTAssertEqual(staged.envelope.sequence, 1)
    }

    func testADifferentWindowStartsItsOwnChain() {
        var chains = CaptureTreeChains(processTag: "run")
        let first = chains.stage(scope: scope(501, "Inbox"), tree: window("Inbox"))
        chains.commit(first)
        let second = chains.stage(scope: scope(501, "Drafts"), tree: window("Drafts"))
        XCTAssertEqual(second.envelope.mode, .fullTree)
        XCTAssertNotEqual(second.envelope.chain, first.envelope.chain)
    }

    func testTheSameWindowInAnotherProcessIsAnotherChain() {
        var chains = CaptureTreeChains(processTag: "run")
        let first = chains.stage(scope: scope(501, "Untitled"), tree: window("Untitled"))
        chains.commit(first)
        let second = chains.stage(scope: scope(777, "Untitled"), tree: window("Untitled"))
        XCTAssertEqual(second.envelope.mode, .fullTree)
        XCTAssertNotEqual(second.envelope.chain, first.envelope.chain)
    }

    /// The heartbeat walks an application and an attached walk starts at a
    /// window; diffing one against the other would delete and re-add the world.
    func testTheHeartbeatAndWindowWalksDoNotShareAChain() {
        var chains = CaptureTreeChains(processTag: "run")
        let heartbeat = chains.stage(
            scope: scope(501, "Inbox", walk: .application),
            tree: CaptureTreeNode(role: "AXApplication", title: "Mail", children: [window("Inbox")])
        )
        chains.commit(heartbeat)
        let edge = chains.stage(scope: scope(501, "Inbox", walk: .window), tree: window("Inbox"))
        XCTAssertEqual(edge.envelope.mode, .fullTree)
        XCTAssertNotEqual(edge.envelope.chain, heartbeat.envelope.chain)
    }

    /// Returning to a window the chain still holds is not a keyframe — that is
    /// the whole reason the chains are keyed per window.
    func testComingBackToAHeldWindowResumesItsChain() {
        var chains = CaptureTreeChains(processTag: "run")
        let first = chains.stage(scope: scope(501, "Inbox"), tree: window("Inbox"))
        chains.commit(first)
        chains.commit(chains.stage(scope: scope(501, "Drafts"), tree: window("Drafts")))
        let back = chains.stage(scope: scope(501, "Inbox"), tree: window("Inbox", children: [button("Reply")]))
        XCTAssertEqual(back.envelope.mode, .diffFromPrevious)
        XCTAssertEqual(back.envelope.chain, first.envelope.chain)
    }

    func testTheChainRebasesAtThirtyDiffs() {
        var chains = CaptureTreeChains(processTag: "run")
        chains.commit(chains.stage(scope: scope(), tree: window("Mail")))
        var modes: [CaptureTreeTextMode] = []
        for step in 1...KeyframePolicy.maxDiffChainLength + 1 {
            let staged = chains.stage(
                scope: scope(),
                tree: window("Mail", children: [button("Row \(step)")])
            )
            modes.append(staged.envelope.mode)
            chains.commit(staged)
        }
        XCTAssertEqual(
            modes.prefix(KeyframePolicy.maxDiffChainLength),
            ArraySlice(repeating: .diffFromPrevious, count: KeyframePolicy.maxDiffChainLength)
        )
        XCTAssertEqual(modes.last, .fullTree, "the cap forces a keyframe")
    }

    /// A keyframe re-bases the chain without renaming it: the sequence keeps
    /// counting so a consumer can order the emissions it received.
    func testAForcedKeyframeKeepsTheChainIdentity() {
        var chains = CaptureTreeChains(processTag: "run")
        let first = chains.stage(scope: scope(), tree: window("Mail"))
        chains.commit(first)
        for step in 1...KeyframePolicy.maxDiffChainLength + 1 {
            chains.commit(
                chains.stage(scope: scope(), tree: window("Mail", children: [button("Row \(step)")]))
            )
        }
        let next = chains.stage(scope: scope(), tree: window("Mail", children: [button("Row last")]))
        XCTAssertEqual(next.envelope.chain, first.envelope.chain)
        XCTAssertEqual(next.envelope.sequence, KeyframePolicy.maxDiffChainLength + 2)
    }

    /// An artifact the shim decided not to emit must not move the chain: the
    /// next diff would otherwise be taken against a tree nobody received.
    func testStagingWithoutCommittingLeavesTheChainWhereItWas() {
        var chains = CaptureTreeChains(processTag: "run")
        chains.commit(chains.stage(scope: scope(), tree: window("Mail", children: [button("Send")])))
        let dropped = chains.stage(
            scope: scope(),
            tree: window("Mail", children: [button("Send"), button("Archive")])
        )
        XCTAssertEqual(dropped.envelope.mode, .diffFromPrevious)
        let next = chains.stage(
            scope: scope(),
            tree: window("Mail", children: [button("Send"), button("Archive")])
        )
        XCTAssertEqual(next.envelope.sequence, 1, "still the first diff off sequence 0")
        XCTAssertTrue(next.envelope.text?.contains("Archive") ?? false)
    }

    func testChainsAreBoundedAndEvictTheLeastRecentlyUsed() {
        var chains = CaptureTreeChains(processTag: "run")
        for index in 0...CaptureTreeChains.maxChains {
            chains.commit(chains.stage(scope: scope(501, "Window \(index)"), tree: window("Window \(index)")))
        }
        XCTAssertEqual(chains.chainCount, CaptureTreeChains.maxChains)
        let evicted = chains.stage(scope: scope(501, "Window 0"), tree: window("Window 0"))
        XCTAssertEqual(evicted.envelope.mode, .fullTree, "an evicted chain costs one keyframe")
    }

    func testFingerprintFollowsTheText() {
        XCTAssertEqual(CaptureTreeFingerprint.of("0 button Send"), CaptureTreeFingerprint.of("0 button Send"))
        XCTAssertNotEqual(CaptureTreeFingerprint.of("0 button Send"), CaptureTreeFingerprint.of("0 button Sent"))
        XCTAssertNotEqual(CaptureTreeFingerprint.of(""), CaptureTreeFingerprint.of("0 button Send"))
    }
}
