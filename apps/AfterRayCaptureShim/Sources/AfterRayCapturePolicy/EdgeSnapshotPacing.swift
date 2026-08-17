/// When an R3 edge snapshot may be walked (docs/input-events-and-t1-acts-plan.md
/// phase 4).
///
/// R1 heartbeats capture on a fixed cadence, so they miss content a person only
/// looked at between two ticks — stepping into a conversation for eight seconds
/// and leaving. R3 fills exactly that hole, and the whole decision of *when* is
/// this state machine: a candidate (frontmost app changed, or a click), a settle
/// window that any further input re-arms, and a token bucket.
///
/// Kept pure and separate from the tap so the timing rules are unit-testable:
/// the failure modes here are "walked the tree while the user was still typing"
/// and "walked it thirty times a minute", and neither is observable in a test
/// that needs a live `CGEventTap`.
package struct EdgeSnapshotPacing: Equatable {
    /// Silence required after the last input before the tree may be walked.
    /// An AX walk is synchronous IPC into the app the user is working in, so
    /// walking mid-interaction is felt as lag in that app.
    package static let settleMs: Int64 = 500
    /// Floor between two walks.
    package static let minSpacingMs: Int64 = 5_000
    /// Ceiling per rolling minute.
    package static let maxPerWindow = 6
    /// Width of the rolling window `maxPerWindow` applies to.
    package static let windowMs: Int64 = 60_000

    /// The armed candidate's most recent re-arm instant, if one is armed.
    private var candidateAtMs: Int64?
    /// Fire instants inside the rolling window, oldest first.
    private var fires: [Int64] = []

    package init() {}

    /// Arms a candidate: the frontmost bundle changed, or a click landed.
    ///
    /// A later candidate replaces an earlier one rather than queueing: the
    /// snapshot's value is the state of the screen *now*, and one walk describes
    /// the newest trigger as well as it describes any older one.
    package mutating func arm(atMs: Int64) {
        candidateAtMs = atMs
    }

    /// Records any input observation. While a candidate is armed this restarts
    /// the settle window — the walk waits for the interaction to finish, however
    /// long that takes. Input with nothing armed is not itself a trigger.
    package mutating func observeInput(atMs: Int64) {
        guard candidateAtMs != nil else { return }
        candidateAtMs = atMs
    }

    /// Whether a walk may run now, consuming the candidate when it answers.
    ///
    /// A candidate refused by the bucket is **dropped**, not held: it would
    /// otherwise fire seconds later against a screen that has moved on, and the
    /// snapshot would be attributed to a trigger it no longer describes. The
    /// next candidate is at most one interaction away.
    package mutating func shouldFire(nowMs: Int64) -> Bool {
        guard let candidate = candidateAtMs else { return false }
        guard nowMs - candidate >= Self.settleMs else { return false }
        candidateAtMs = nil
        fires.removeAll { nowMs - $0 >= Self.windowMs }
        if let last = fires.last, nowMs - last < Self.minSpacingMs {
            return false
        }
        if fires.count >= Self.maxPerWindow {
            return false
        }
        fires.append(nowMs)
        return true
    }

    /// Whether a candidate is waiting — for logging and tests only.
    package var isArmed: Bool { candidateAtMs != nil }
}
