import CoreGraphics

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
