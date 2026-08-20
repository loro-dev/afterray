import SwiftUI

/// Which scroll phases count as "the user moved the transcript".
///
/// Only a user scroll may switch following off (`ChatAutoScrollState.observe`),
/// so getting this wrong is silent: map `.animating` in and following turns
/// itself off every time it succeeds, because our own `scrollTo` looks like
/// the user leaving.
enum ChatScrollPhaseIntent {
    static func isUserScrolling(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .interacting, .decelerating, .tracking:
            true
        case .idle, .animating:
            false
        @unknown default:
            false
        }
    }
}

struct ChatScrollMetrics: Equatable, Sendable {
    let distanceFromBottom: CGFloat
    let isUserScrolling: Bool
    /// Document height. Used to skip `scrollTo` across a large collapse.
    let contentHeight: CGFloat

    init(
        distanceFromBottom: CGFloat,
        isUserScrolling: Bool,
        contentHeight: CGFloat = 0
    ) {
        self.distanceFromBottom = distanceFromBottom
        self.isUserScrolling = isUserScrolling
        self.contentHeight = contentHeight
    }
}

/// The half of `ChatScrollMetrics` that comes from `onScrollGeometryChange`.
///
/// Kept apart from the phase because the two arrive on different callbacks and
/// at very different rates: geometry on every frame of a scroll, phase a
/// handful of times per gesture. Whichever fires combines its own value with
/// the other's last one.
struct ChatScrollGeometry: Equatable, Sendable {
    var distanceFromBottom: CGFloat = 0
    var contentHeight: CGFloat = 0

    func metrics(isUserScrolling: Bool) -> ChatScrollMetrics {
        ChatScrollMetrics(
            distanceFromBottom: distanceFromBottom,
            isUserScrolling: isUserScrolling,
            contentHeight: contentHeight
        )
    }
}

/// Scroll signals held off `@State`: geometry changes on every frame of a
/// scroll and must not rebuild the transcript. Only `ChatAutoScrollState`,
/// which these feed, is allowed to invalidate the view.
final class ChatScrollRuntime {
    var geometry = ChatScrollGeometry()
    var isUserScrolling = false
}
