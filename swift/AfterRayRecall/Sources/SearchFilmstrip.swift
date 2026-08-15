import CoreGraphics
import SwiftUI

/// The bottom bar while a search is open: one thumbnail per matched frame,
/// newest on the right, under the same fixed playhead the app timeline uses.
///
/// It replaces `AppUsageTimeline` rather than sitting beside it. During a
/// search, wall-clock browsing is not the task — moving between hits is.
struct SearchFilmstrip: View {
    let session: RecallSearchSession
    let tuning: RecallVisualTuning
    let selectedDate: Date
    let thumbnailLoader: RecallThumbnailLoader
    let onSelectIndex: (Int) -> Void
    let onViewportWidthChange: (CGFloat) -> Void

    private static let captionHeight: CGFloat = 16
    private static let stripHeight = SearchFilmstripLayout.cellHeight + captionHeight + 10

    var body: some View {
        VStack(spacing: 9) {
            // Captions are relative ("5M"), so they have to be recomputed as
            // time passes, not just when the selection changes.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                strip(nowMs: Int64(context.date.timeIntervalSince1970 * 1_000))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.stripHeight)

            HStack(spacing: 7) {
                Image(systemName: "arrow.left.and.right")
                Text("Swipe or ↑↓ to walk matches · Esc to close")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func strip(nowMs: Int64) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let layout = SearchFilmstripLayout(
                count: session.frames.count,
                viewportWidth: width
            )
            ZStack(alignment: .leading) {
                Color.black.opacity(0.001)

                // The fade has to be anchored to the viewport, so it is applied
                // to a viewport-sized container rather than to the cells. A
                // mask on the offset row would follow the row's *pre-offset*
                // layout frame and erase the cells instead of their edges.
                ZStack(alignment: .leading) {
                    cells(layout: layout, nowMs: nowMs)
                        .offset(x: layout.offset(forIndex: session.selectedIndex))
                }
                .frame(width: width, height: Self.stripHeight, alignment: .leading)
                // Cells are pictures, so a hard cut at the viewport edge reads
                // as broken in a way a cut colour bar does not.
                .mask(edgeFade(width: width))

                // A short tick, not a full-height rule: the app timeline draws
                // its playhead through a continuous bar, but the same line
                // across a thumbnail bisects the picture and strikes out the
                // caption under it. The selected cell is already unmistakable.
                Rectangle()
                    .fill(RecallPalette.ray)
                    .frame(width: 2, height: 7)
                    .position(x: width / 2, y: 3.5)
                    .shadow(color: RecallPalette.ray.opacity(0.9), radius: 5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .clipped()
            .onAppear { onViewportWidthChange(width) }
            .onChange(of: width) { _, newWidth in onViewportWidthChange(newWidth) }
        }
    }

    /// Fades roughly one cell's worth at each edge so partially visible
    /// thumbnails dissolve instead of being sliced.
    private func edgeFade(width: CGFloat) -> some View {
        let fade = min(SearchFilmstripLayout.cellWidth, max(width / 6, 1)) / max(width, 1)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Only the cells that can reach the viewport are built, and each is placed
    /// at its own x rather than stacked, so skipping the rest costs nothing —
    /// an `HStack` would have to lay out every cell it never draws just to know
    /// where the next one goes.
    private func cells(layout: SearchFilmstripLayout, nowMs: Int64) -> some View {
        ZStack(alignment: .leading) {
            ForEach(slots(layout: layout)) { slot in
                SearchFilmstripCell(
                    frame: slot.frame,
                    isSelected: slot.index == session.selectedIndex,
                    nowMs: nowMs,
                    loader: thumbnailLoader
                )
                .offset(x: layout.centerX(index: slot.index) - SearchFilmstripLayout.cellWidth / 2)
                .onTapGesture { onSelectIndex(slot.index) }
            }
        }
        .frame(width: layout.contentWidth, height: Self.stripHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: session.selectedIndex)
    }

    private func slots(layout: SearchFilmstripLayout) -> [FilmstripSlot] {
        layout.visibleIndices(around: session.selectedIndex).compactMap { index in
            guard session.frames.indices.contains(index) else { return nil }
            return FilmstripSlot(index: index, frame: session.frames[index])
        }
    }
}

/// A cell the strip actually builds: where it ranks, and the frame that sits
/// there. Identity follows the frame, so a new search never shows the previous
/// one's thumbnails in the same slots.
private struct FilmstripSlot: Identifiable {
    let index: Int
    let frame: SearchFrame

    var id: String { frame.momentId }
}

private struct SearchFilmstripCell: View {
    let frame: SearchFrame
    let isSelected: Bool
    let nowMs: Int64
    let loader: RecallThumbnailLoader

    @State private var image: CGImage?

    private var cornerRadius: CGFloat { 8 }

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
                .frame(
                    width: SearchFilmstripLayout.cellWidth,
                    height: SearchFilmstripLayout.cellHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? RecallPalette.ray : .white.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .shadow(
                    color: isSelected ? RecallPalette.ray.opacity(0.55) : .clear,
                    radius: 9
                )
                .scaleEffect(isSelected ? 1.06 : 1)

            Text(RelativeStamp.short(fromMs: frame.capturedAtMs, nowMs: nowMs))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.55))
        }
        .frame(width: SearchFilmstripLayout.cellWidth)
        .contentShape(Rectangle())
        // Deliberately no `.help`: the excerpt is a wall of OCR text nobody can
        // read from a tooltip, and keeping one registered per cell made every
        // scroll tick pay for tracking areas the strip does not need.
        .task(id: frame.momentId) {
            image = await RecallThumbnailCache.shared.image(
                momentID: frame.momentId,
                loader: loader
            )
        }
    }

    /// Cells are built and dropped as the strip travels, so the cache is read
    /// during layout too: waiting for the `task` to hand back an image already
    /// in memory shows a placeholder for a frame on every cell that returns.
    private var displayImage: CGImage? {
        image ?? RecallThumbnailCache.shared.cached(momentID: frame.momentId)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = displayImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
        } else {
            // Tinted by moment id so cells stay visually distinct while their
            // pixels are still in flight, instead of a row of identical greys.
            RecallPalette.appColor(seed: frame.momentId)
                .opacity(0.28)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                }
        }
    }
}
