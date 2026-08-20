import Foundation

/// When the history list should jump to the playhead.
///
/// **Only when the scrub settles.** The highlight itself still moves live —
/// that is `isCurrent` on the row and costs one row's redraw — but the
/// document does not chase it.
///
/// Following on every slot change looked cheap: a boundary is half an hour of
/// recorded time. Dragging across a day crosses ~48 of them in a couple of
/// seconds, and each one rebuilt the panel and asked its `ScrollView` to
/// re-measure. Comparing the slowest seconds of a scrub against the fastest in
/// one recording, `ScrollViewLayoutComputer.sizeThatFits` was 19x higher and
/// `DaySummaryPanelContent.body` 10x — with the main thread *less* busy
/// overall, so those were frames lost to relayout, not to arithmetic.
///
/// It also read badly: the panel bounced around under a finger that was
/// nowhere near it.
enum HistoryDocumentFollow {
    static func shouldFollow(
        previousSlot: Int64?,
        currentSlot: Int64?,
        settleRequested: Bool
    ) -> Bool {
        settleRequested && currentSlot != nil
    }
}
