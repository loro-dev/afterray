import Foundation

/// When the history list should reveal the playhead's card.
///
/// Live again, on every slot change — but "reveal" now means
/// `HistoryListLayout.offsetToReveal`, which answers nil when the card is
/// already on screen. That is where the cost went: following used to jump the
/// card to the top of the panel on every boundary, and a drag across one day
/// crosses ~48 of them in a couple of seconds. Each jump rebuilt the panel and
/// re-measured its `ScrollView`; comparing the slowest seconds of a scrub with
/// the fastest, those were 10x and 19x higher while the main thread was *less*
/// busy overall — frames lost to relayout, not to arithmetic.
///
/// Gating the *decision* on settle fixed the cost and broke the feature: the
/// panel stopped tracking until you let go. Gating the *movement* on whether
/// the card is actually off screen fixes both.
enum HistoryDocumentFollow {
    static func shouldFollow(
        previousSlot: Int64?,
        currentSlot: Int64?,
        settleRequested: Bool
    ) -> Bool {
        guard currentSlot != nil else { return false }
        return settleRequested || currentSlot != previousSlot
    }
}
