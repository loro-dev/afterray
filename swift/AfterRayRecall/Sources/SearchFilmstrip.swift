import CoreGraphics
import SwiftUI

/// The bottom bar while a search is open: one thumbnail per matched frame,
/// newest on the left, under the same fixed playhead the app timeline uses.
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

    private func cells(layout: SearchFilmstripLayout, nowMs: Int64) -> some View {
        HStack(spacing: SearchFilmstripLayout.cellGap) {
            ForEach(Array(session.frames.enumerated()), id: \.element.id) { index, frame in
                SearchFilmstripCell(
                    frame: frame,
                    isSelected: index == session.selectedIndex,
                    nowMs: nowMs,
                    loader: thumbnailLoader
                )
                .onTapGesture { onSelectIndex(index) }
            }
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: session.selectedIndex)
    }
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
        .help(frame.excerpt)
        .task(id: frame.momentId) {
            image = await RecallThumbnailCache.shared.image(
                momentID: frame.momentId,
                loader: loader
            )
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
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
