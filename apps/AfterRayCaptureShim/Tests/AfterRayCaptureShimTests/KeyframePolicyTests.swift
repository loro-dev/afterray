@testable import AfterRayCapturePolicy
import XCTest

/// keyframe / diff / skip, from docs/event-capture-v2-plan.md §4.
final class KeyframePolicyTests: XCTestCase {
    func testAWindowSwitchAlwaysEmitsAFullTree() {
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: true, diffChainLength: 0, fingerprintChanged: true),
            .keyframe
        )
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: true, diffChainLength: 29, fingerprintChanged: true),
            .keyframe
        )
    }

    /// A window change outranks stillness: the previous tree describes another
    /// window, so "the digest matches" cannot mean "nothing moved" across it.
    func testAWindowSwitchOutranksAnUnchangedFingerprint() {
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: true, diffChainLength: 3, fingerprintChanged: false),
            .keyframe
        )
    }

    func testAStillTreeIsNotEmitted() {
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: false, diffChainLength: 0, fingerprintChanged: false),
            .skip
        )
        XCTAssertEqual(
            KeyframePolicy.decide(
                windowChanged: false,
                diffChainLength: KeyframePolicy.maxDiffChainLength + 5,
                fingerprintChanged: false
            ),
            .skip,
            "an over-long chain is still nothing to say"
        )
    }

    func testAMovedTreeInsideTheChainDiffs() {
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: false, diffChainLength: 0, fingerprintChanged: true),
            .diff
        )
        XCTAssertEqual(
            KeyframePolicy.decide(
                windowChanged: false,
                diffChainLength: KeyframePolicy.maxDiffChainLength - 1,
                fingerprintChanged: true
            ),
            .diff,
            "the last link before the cap is still a diff"
        )
    }

    func testTheChainIsCappedAtThirty() {
        XCTAssertEqual(KeyframePolicy.maxDiffChainLength, 30)
        XCTAssertEqual(
            KeyframePolicy.decide(
                windowChanged: false,
                diffChainLength: KeyframePolicy.maxDiffChainLength,
                fingerprintChanged: true
            ),
            .keyframe,
            "the cap is inclusive: thirty diffs, then re-base"
        )
        XCTAssertEqual(
            KeyframePolicy.decide(
                windowChanged: false,
                diffChainLength: KeyframePolicy.maxDiffChainLength + 100,
                fingerprintChanged: true
            ),
            .keyframe
        )
    }

    /// The whole truth table, spelled out once so a later edit has to argue with
    /// every cell rather than the one it remembered.
    func testTruthTable() {
        let expected: [(Bool, Int, Bool, CaptureFrameDecision)] = [
            (false, 0, false, .skip),
            (false, 30, false, .skip),
            (false, 0, true, .diff),
            (false, 29, true, .diff),
            (false, 30, true, .keyframe),
            (true, 0, false, .keyframe),
            (true, 30, false, .keyframe),
            (true, 0, true, .keyframe),
            (true, 30, true, .keyframe),
        ]
        for (windowChanged, chain, fingerprintChanged, decision) in expected {
            XCTAssertEqual(
                KeyframePolicy.decide(
                    windowChanged: windowChanged,
                    diffChainLength: chain,
                    fingerprintChanged: fingerprintChanged
                ),
                decision,
                "window=\(windowChanged) chain=\(chain) fingerprint=\(fingerprintChanged)"
            )
        }
    }

    func testAKeyframeRebasesTheChainAndADiffExtendsIt() {
        XCTAssertEqual(KeyframePolicy.chainLength(after: .keyframe, previous: 29), 0)
        XCTAssertEqual(KeyframePolicy.chainLength(after: .diff, previous: 29), 30)
        XCTAssertEqual(
            KeyframePolicy.chainLength(after: .skip, previous: 7),
            7,
            "a skip emitted nothing, so it extends no chain"
        )
    }

    /// Driving the policy the way the shim will: a window switch, then a long
    /// quiet run of edits, and the chain must re-base exactly once at the cap.
    func testALongRunReBasesExactlyAtTheCap() {
        var chain = 0
        var decisions: [CaptureFrameDecision] = []
        for step in 0..<70 {
            let decision = KeyframePolicy.decide(
                windowChanged: step == 0,
                diffChainLength: chain,
                fingerprintChanged: true
            )
            chain = KeyframePolicy.chainLength(after: decision, previous: chain)
            decisions.append(decision)
        }
        let keyframeSteps = decisions.enumerated()
            .filter { $0.element == .keyframe }
            .map(\.offset)
        XCTAssertEqual(keyframeSteps, [0, 31, 62], "one opening keyframe, then every thirty diffs")
        XCTAssertEqual(decisions.filter { $0 == .diff }.count, 67)
        XCTAssertFalse(decisions.contains(.skip))
    }

    /// Skipped frames must not silently age out the chain: a person reading one
    /// still window for ten minutes should not force a full tree on the first
    /// thing they touch.
    func testSkipsDoNotAdvanceTheChain() {
        var chain = 0
        for _ in 0..<100 {
            let decision = KeyframePolicy.decide(
                windowChanged: false,
                diffChainLength: chain,
                fingerprintChanged: false
            )
            XCTAssertEqual(decision, .skip)
            chain = KeyframePolicy.chainLength(after: decision, previous: chain)
        }
        XCTAssertEqual(chain, 0)
        XCTAssertEqual(
            KeyframePolicy.decide(windowChanged: false, diffChainLength: chain, fingerprintChanged: true),
            .diff
        )
    }
}
