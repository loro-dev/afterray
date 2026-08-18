import CoreGraphics

/// User intent for a growing chat transcript.
///
/// Streaming follow is `defaultScrollAnchor(.bottom)` in the view — this
/// machine never asks for `scrollTo` on a geometry tick. Only a live user
/// scroll can disable following, so a growing last bubble is not mistaken
/// for the user moving away.
///
/// `scrollTo` stays discrete: open / switch, Latest, a new send, and at
/// most one snap when the turn ends. A large content collapse never pairs
/// with that snap (it used to dump the viewport into empty space).
struct ChatAutoScrollState: Equatable, Sendable {
    static let nearBottomThreshold: CGFloat = 40
    /// Reasoning fold / streaming-row swap at end of turn.
    static let collapseSkipThreshold: CGFloat = 24
    /// One-shot end-of-stream residual. Not used for continuous stick.
    static let stickDistanceThreshold: CGFloat = 1

    private(set) var isFollowingLatest = true
    private(set) var distanceFromBottom: CGFloat = 0
    private(set) var lastContentHeight: CGFloat = 0
    /// One leftover snap after `isSending` falls, consumed by the next `decide`.
    private(set) var pendingEndOfStreamSnap = false
    /// One pin after opening / switching a conversation, so history landing
    /// idle does not depend on continuous frame-change stick.
    private(set) var pendingConversationPin = true

    var shouldShowLatestButton: Bool {
        !isFollowingLatest && distanceFromBottom > Self.nearBottomThreshold
    }

    mutating func observe(distanceFromBottom: CGFloat, isUserScrolling: Bool) {
        self.distanceFromBottom = max(0, distanceFromBottom)
        guard isUserScrolling else { return }
        isFollowingLatest = self.distanceFromBottom <= Self.nearBottomThreshold
        if !isFollowingLatest {
            pendingEndOfStreamSnap = false
            pendingConversationPin = false
        }
    }

    mutating func followLatest() {
        isFollowingLatest = true
        pendingEndOfStreamSnap = false
    }

    mutating func resetForConversation() {
        isFollowingLatest = true
        distanceFromBottom = 0
        lastContentHeight = 0
        pendingEndOfStreamSnap = false
        pendingConversationPin = true
    }

    /// `isSending` flipped. A new send is user intent to see the reply.
    /// Stream end never scrolls here — the next `decide` may snap once.
    mutating func noteSendingChanged(_ isSending: Bool) -> ChatScrollAction {
        if isSending {
            isFollowingLatest = true
            pendingEndOfStreamSnap = false
            pendingConversationPin = false
            return .scrollToLatest
        }
        pendingEndOfStreamSnap = isFollowingLatest
        return .none
    }

    /// History finished loading, or the first idle bubbles appeared.
    mutating func noteConversationContentReady() -> ChatScrollAction {
        guard isFollowingLatest, pendingConversationPin else { return .none }
        pendingConversationPin = false
        return .scrollToLatest
    }

    /// Read-only against the scroll view: update follow intent, never stick
    /// while a turn is streaming. `scrollTo` from bounds-change is the
    /// main-thread 100% loop.
    mutating func decide(metrics: ChatScrollMetrics, isSending: Bool) -> ChatScrollAction {
        let previousHeight = lastContentHeight
        let heightDelta = metrics.contentHeight - previousHeight
        if metrics.contentHeight > 0 {
            lastContentHeight = metrics.contentHeight
        }

        observe(
            distanceFromBottom: metrics.distanceFromBottom,
            isUserScrolling: metrics.isUserScrolling
        )

        // Never fight a live gesture, even while a turn is streaming.
        if metrics.isUserScrolling {
            pendingEndOfStreamSnap = false
            return .none
        }

        guard isFollowingLatest else { return .none }

        if isSending {
            return .none
        }

        guard pendingEndOfStreamSnap else { return .none }

        let collapsed = previousHeight > 0
            && metrics.contentHeight > 0
            && heightDelta <= -Self.collapseSkipThreshold
        if collapsed {
            pendingEndOfStreamSnap = false
            return .none
        }

        pendingEndOfStreamSnap = false
        return metrics.distanceFromBottom > Self.stickDistanceThreshold
            ? .scrollToLatest
            : .none
    }
}

enum ChatScrollAction: Equatable, Sendable {
    case none
    case scrollToLatest
}
