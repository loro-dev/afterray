import AppKit
import SwiftUI

/// Telegram-style windowed list on AppKit.
///
/// Telegram-iOS `ListView` cannot ship here (GPL-2, UIKit, AsyncDisplayKit).
/// This is the same *model* on macOS: the scroll view only provides pan and
/// a real content size; row views are subviews of a flipped document, and
/// only the viewport plus `invisibleInset` (~500pt) are mounted. Height is
/// guessed, then measured; a delta above the fold moves the clip origin so
/// the document does not jump. Prefetch is "visible index within 5 of the
/// loaded edge", not an `onAppear` on an unmounted sentinel.
struct HistoryListScrollView<Row: View>: NSViewRepresentable {
    var items: [HistoryListItem]
    var isLoadingMore: Bool
    var hasMore: Bool
    var showsIndicator: Bool
    var followID: String?
    var followGeneration: Int
    var onLoadMore: () -> Void
    var onStickyChip: (DayHeadingChip?) -> Void
    var row: (HistoryListItem) -> Row

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scrollView = coordinator.scrollView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        let clip = HistoryListClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.documentView = coordinator.document
        ScrollFenceRegistry.shared.register(scrollView)
        coordinator.observeClipView()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        scrollView.hasVerticalScroller = showsIndicator
        coordinator.items = items
        coordinator.isLoadingMore = isLoadingMore
        coordinator.hasMore = hasMore
        coordinator.makeRow = { AnyView(row($0)) }
        coordinator.onLoadMore = onLoadMore
        coordinator.onStickyChip = onStickyChip
        coordinator.reload()
        if followGeneration != coordinator.appliedFollowGeneration {
            coordinator.pendingFollowID = followID
            coordinator.pendingFollowGeneration = followGeneration
            coordinator.flushFollow()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let scrollView = NSScrollView()
        let document = HistoryListDocumentView()
        let cache = HistoryRowHeightCache()
        var items: [HistoryListItem] = []
        var isLoadingMore = false
        var hasMore = false
        var makeRow: (HistoryListItem) -> AnyView = { _ in AnyView(EmptyView()) }
        var onLoadMore: () -> Void = {}
        var onStickyChip: (DayHeadingChip?) -> Void = { _ in }
        var appliedFollowGeneration = -1
        var pendingFollowGeneration = -1
        var pendingFollowID: String?
        var ignoreScroll = false
        private var boundsObserver: NSObjectProtocol?
        private var lastChip: DayHeadingChip?
        private var lastLoadMoreAt: CFAbsoluteTime = 0

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func observeClipView() {
            guard boundsObserver == nil else { return }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.ignoreScroll else { return }
                    self.updateVisible(remeasure: false)
                    self.flushFollow()
                }
            }
        }

        func reload() {
            updateVisible(remeasure: true)
        }

        func flushFollow() {
            guard pendingFollowGeneration != appliedFollowGeneration else { return }
            guard scrollView.contentView.bounds.width > 1 else { return }
            appliedFollowGeneration = pendingFollowGeneration
            if let pendingFollowID {
                scrollTo(id: pendingFollowID)
            }
        }

        var offset: CGFloat {
            max(0, scrollView.contentView.documentVisibleRect.origin.y)
        }

        var viewportHeight: CGFloat {
            scrollView.contentView.bounds.height
        }

        var rowWidth: CGFloat {
            max(1, document.bounds.width - HistoryListLayout.horizontalInset * 2)
        }

        func heights() -> [CGFloat] {
            HistoryListLayout.heights(
                items: items,
                cache: cache,
                isLoadingMore: isLoadingMore
            )
        }

        func originEdges(from rowHeights: [CGFloat]) -> [CGFloat] {
            HistoryListLayout.origins(heights: rowHeights)
        }

        func contentHeight(origins: [CGFloat]) -> CGFloat {
            (origins.last ?? 0) + HistoryListLayout.bottomPadding
        }

        func scrollTo(id: String) {
            let heights = heights()
            let origins = originEdges(from: heights)
            guard let index = HistoryListLayout.index(of: id, in: items),
                  index < origins.count
            else { return }
            setOffset(origins[index])
            updateVisible(remeasure: true)
        }

        func setOffset(_ y: CGFloat) {
            ignoreScroll = true
            let maxY = max(0, document.frame.height - viewportHeight)
            let next = min(max(0, y), maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: next))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            ignoreScroll = false
        }

        func updateVisible(remeasure: Bool) {
            let width = scrollView.contentView.bounds.width
            guard width > 1 else { return }

            if items.isEmpty {
                for host in document.hosts.values { host.removeFromSuperview() }
                document.hosts.removeAll()
                document.frame = NSRect(x: 0, y: 0, width: width, height: viewportHeight)
                return
            }

            var heights = heights()
            var origins = originEdges(from: heights)
            var offset = self.offset
            let viewport = viewportHeight
            document.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: max(contentHeight(origins: origins), viewport)
            )

            let range = HistoryListLayout.visibleRange(
                origins: origins,
                offset: offset,
                viewportHeight: viewport
            )
            let visibleIDs = Set(items[range].map(\.id))

            for (id, host) in document.hosts where !visibleIDs.contains(id) {
                host.removeFromSuperview()
                document.hosts.removeValue(forKey: id)
            }

            var heightChanged = false
            for index in range {
                let item = items[index]
                let host = document.host(for: item.id, row: makeRow(item))
                if remeasure {
                    host.rootView = makeRow(item)
                }
                let measured = document.measure(host, width: rowWidth)
                let previous = heights[index]
                if abs(measured - previous) >= 1 {
                    offset += HistoryListLayout.offsetDeltaAfterHeightChange(
                        rowOrigin: origins[index],
                        viewportOffset: offset,
                        heightDelta: measured - previous
                    )
                    cache.record(id: item.id, measured: measured)
                    heights[index] = measured
                    heightChanged = true
                }
            }

            if heightChanged {
                origins = originEdges(from: heights)
                document.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: max(contentHeight(origins: origins), viewport)
                )
                setOffset(offset)
            }

            for index in range {
                let item = items[index]
                guard let host = document.hosts[item.id] else { continue }
                host.rootView = makeRow(item)
                let height = heights[index]
                host.frame = NSRect(
                    x: HistoryListLayout.horizontalInset,
                    y: origins[index],
                    width: rowWidth,
                    height: height
                )
            }

            let chip = HistoryStickyHeading.chip(items: items, origins: origins, offset: self.offset)
            if chip != lastChip {
                lastChip = chip
                onStickyChip(chip)
            }

            let visibleLast = range.isEmpty ? -1 : range.upperBound - 1
            if hasMore,
               HistoryListLayout.shouldLoadMore(
                   visibleLastIndex: visibleLast,
                   itemCount: items.count,
                   offset: self.offset,
                   viewportHeight: viewport,
                   contentHeight: contentHeight(origins: origins)
               )
            {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastLoadMoreAt > 0.2 {
                    lastLoadMoreAt = now
                    onLoadMore()
                }
            }
        }
    }
}

final class HistoryListDocumentView: NSView {
    var hosts: [String: NSHostingView<AnyView>] = [:]

    override var isFlipped: Bool { true }

    func host(for id: String, row: AnyView) -> NSHostingView<AnyView> {
        if let existing = hosts[id] {
            return existing
        }
        let host = NSHostingView(rootView: row)
        host.sizingOptions = [.intrinsicContentSize]
        hosts[id] = host
        addSubview(host)
        return host
    }

    func measure(_ host: NSHostingView<AnyView>, width: CGFloat) -> CGFloat {
        host.frame.size.width = width
        host.invalidateIntrinsicContentSize()
        return max(1, ceil(host.fittingSize.height))
    }
}

final class HistoryListClipView: NSClipView {
    override var isFlipped: Bool { true }
}
