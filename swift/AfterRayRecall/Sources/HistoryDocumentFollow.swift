import Foundation

/// When the history list should jump to the playhead. Live scrubbing only
/// moves the document when the highlighted slot changes; the settle pulse
/// remains a final correction after the glide stops.
enum HistoryDocumentFollow {
    static func shouldFollow(
        previousSlot: Int64?,
        currentSlot: Int64?,
        settleRequested: Bool
    ) -> Bool {
        settleRequested || (currentSlot != nil && currentSlot != previousSlot)
    }
}
