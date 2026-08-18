import XCTest
@testable import AfterRayRecall

final class ChatAutoScrollStateTests: XCTestCase {
    func testContentGrowthDoesNotDisableFollowing() {
        var state = ChatAutoScrollState()

        state.observe(distanceFromBottom: 240, isUserScrolling: false)

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testUserScrollingAwayDisablesFollowingAndShowsLatestButton() {
        var state = ChatAutoScrollState()

        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        XCTAssertFalse(state.isFollowingLatest)
        XCTAssertTrue(state.shouldShowLatestButton)
    }

    func testSmallLiveScrollNearBottomKeepsFollowing() {
        var state = ChatAutoScrollState()

        state.observe(
            distanceFromBottom: ChatAutoScrollState.nearBottomThreshold - 1,
            isUserScrolling: true
        )

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testReturningToBottomResumesFollowing() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        state.observe(distanceFromBottom: 0, isUserScrolling: true)

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testLatestButtonAndConversationResetResumeFollowing() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        state.followLatest()
        XCTAssertTrue(state.isFollowingLatest)

        state.observe(distanceFromBottom: 80, isUserScrolling: true)
        state.resetForConversation()
        XCTAssertEqual(state, ChatAutoScrollState())
    }

    func testIdleFrameChangeWhileFollowingDoesNotStick() {
        var state = ChatAutoScrollState()
        _ = state.noteConversationContentReady()

        let action = state.decide(
            metrics: .stub(distance: 80, height: 900),
            isSending: false
        )

        XCTAssertEqual(action, .none)
        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testStreamingFrameDriftWhileFollowingDoesNotScrollTo() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(true)

        let action = state.decide(
            metrics: .stub(distance: 12, height: 640),
            isSending: true
        )

        XCTAssertEqual(action, .none)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testLiveUserScrollNeverRequestsStick() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(true)

        let action = state.decide(
            metrics: .stub(distance: 12, userScrolling: true, height: 640),
            isSending: true
        )

        XCTAssertEqual(action, .none)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testUserScrollAwayStaysDisabledOnIdleLayout() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 120, isUserScrolling: true)

        let action = state.decide(
            metrics: .stub(distance: 180, height: 1_200),
            isSending: false
        )

        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.isFollowingLatest)
        XCTAssertTrue(state.shouldShowLatestButton)
    }

    func testUserScrollAwayStaysDisabledDuringStreamingGrowth() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 160, isUserScrolling: true)

        let action = state.decide(
            metrics: .stub(distance: 200, height: 1_400),
            isSending: true
        )

        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.isFollowingLatest)
    }

    func testStreamingGrowthIsNotInterpretedAsUserScroll() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(true)
        _ = state.decide(metrics: .stub(distance: 0, height: 400), isSending: true)

        let action = state.decide(
            metrics: .stub(distance: 18, height: 520),
            isSending: true
        )

        XCTAssertEqual(action, .none)
        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.shouldShowLatestButton)
    }

    func testStreamingEndDoesNotScrollUntilNextDecide() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)

        XCTAssertEqual(state.noteSendingChanged(false), .none)
        XCTAssertTrue(state.pendingEndOfStreamSnap)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testStreamingEndWhileDriftedSnapsOnce() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)
        _ = state.noteSendingChanged(false)

        let first = state.decide(
            metrics: .stub(distance: 20, height: 810),
            isSending: false
        )
        let second = state.decide(
            metrics: .stub(distance: 20, height: 810),
            isSending: false
        )

        XCTAssertEqual(first, .scrollToLatest)
        XCTAssertEqual(second, .none)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testStreamingEndAtBottomDoesNotSnap() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)
        _ = state.noteSendingChanged(false)

        let action = state.decide(
            metrics: .stub(distance: 0, height: 804),
            isSending: false
        )

        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
    }

    func testStreamingEndCollapseDoesNotSnap() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)
        _ = state.noteSendingChanged(false)

        let action = state.decide(
            metrics: .stub(distance: 40, height: 200),
            isSending: false
        )

        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testSmallShrinkWhileStreamingDoesNotScrollTo() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(true)
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)

        let action = state.decide(
            metrics: .stub(distance: 5, height: 790),
            isSending: true
        )

        XCTAssertEqual(action, .none)
    }

    func testStreamingGeometryNeverRequestsScrollTo() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(true)

        let far = state.decide(
            metrics: .stub(distance: 240, height: 1_200),
            isSending: true
        )
        let again = state.decide(
            metrics: .stub(distance: 8, height: 1_280),
            isSending: true
        )

        XCTAssertEqual(far, .none)
        XCTAssertEqual(again, .none)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testLiveScrollCancelsPendingEndSnap() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 0, height: 800), isSending: true)
        _ = state.noteSendingChanged(false)

        let action = state.decide(
            metrics: .stub(distance: 24, userScrolling: true, height: 800),
            isSending: false
        )

        XCTAssertEqual(action, .none)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testNewSendReenablesFollowAndScrolls() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 160, isUserScrolling: true)

        let action = state.noteSendingChanged(true)

        XCTAssertEqual(action, .scrollToLatest)
        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
        XCTAssertFalse(state.pendingConversationPin)
    }

    func testFollowLatestClearsPendingEndSnap() {
        var state = ChatAutoScrollState()
        _ = state.noteSendingChanged(false)
        XCTAssertTrue(state.pendingEndOfStreamSnap)

        state.followLatest()

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertFalse(state.pendingEndOfStreamSnap)
    }

    func testConversationContentReadyPinsOnce() {
        var state = ChatAutoScrollState()

        XCTAssertEqual(state.noteConversationContentReady(), .scrollToLatest)
        XCTAssertEqual(state.noteConversationContentReady(), .none)
        XCTAssertFalse(state.pendingConversationPin)
    }

    func testConversationContentReadyDoesNotOverrideUserScrollAway() {
        var state = ChatAutoScrollState()
        state.observe(distanceFromBottom: 200, isUserScrolling: true)

        XCTAssertEqual(state.noteConversationContentReady(), .none)
        XCTAssertFalse(state.isFollowingLatest)
        XCTAssertFalse(state.pendingConversationPin)
    }

    func testResetClearsPendingFlagsAndHeight() {
        var state = ChatAutoScrollState()
        _ = state.decide(metrics: .stub(distance: 12, height: 640), isSending: true)
        _ = state.noteSendingChanged(false)
        state.observe(distanceFromBottom: 90, isUserScrolling: true)

        state.resetForConversation()

        XCTAssertEqual(state, ChatAutoScrollState())
    }
}

private extension ChatScrollMetrics {
    static func stub(
        distance: CGFloat,
        userScrolling: Bool = false,
        height: CGFloat = 0
    ) -> ChatScrollMetrics {
        ChatScrollMetrics(
            distanceFromBottom: distance,
            isUserScrolling: userScrolling,
            contentHeight: height
        )
    }
}
