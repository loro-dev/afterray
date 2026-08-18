import AppKit
import SwiftUI

/// macOS 14 compatibility bridge for the scroll geometry and live-scroll
/// signals that SwiftUI exposes natively only on macOS 15.
///
/// Read-only: the callback must not request `scrollTo`. `updateNSView`
/// must not re-emit when already attached — that plus a state write is a
/// layout loop.
struct ChatScrollObserver: NSViewRepresentable {
    let onChange: @MainActor (ChatScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        attach(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        attach(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func attach(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.attach(to: view.enclosingScrollView)
        }
    }

    @MainActor
    final class Coordinator {
        var onChange: @MainActor (ChatScrollMetrics) -> Void

        private weak var scrollView: NSScrollView?
        private weak var documentView: NSView?
        private var observers: [NSObjectProtocol] = []
        private var isLiveScrolling = false
        private var lastMetrics: ChatScrollMetrics?

        init(onChange: @escaping @MainActor (ChatScrollMetrics) -> Void) {
            self.onChange = onChange
        }

        func attach(to candidate: NSScrollView?) {
            guard let candidate else { return }
            guard scrollView !== candidate || documentView !== candidate.documentView else {
                return
            }

            detach()
            scrollView = candidate
            documentView = candidate.documentView
            candidate.contentView.postsBoundsChangedNotifications = true
            candidate.documentView?.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: candidate.contentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.emitMetrics() }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: candidate.documentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.emitMetrics() }
                },
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: candidate,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isLiveScrolling = true
                        self?.emitMetrics()
                    }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: candidate,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.emitMetrics()
                        self?.isLiveScrolling = false
                    }
                },
            ]
            emitMetrics()
        }

        func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            scrollView = nil
            documentView = nil
            isLiveScrolling = false
            lastMetrics = nil
        }

        private func emitMetrics() {
            guard let scrollView, let documentView else { return }
            let visible = scrollView.documentVisibleRect
            let distance: CGFloat
            if documentView.isFlipped {
                distance = documentView.bounds.maxY - visible.maxY
            } else {
                distance = visible.minY - documentView.bounds.minY
            }
            let metrics = ChatScrollMetrics(
                distanceFromBottom: max(0, distance),
                isUserScrolling: isLiveScrolling,
                contentHeight: documentView.bounds.height
            )
            guard lastMetrics != metrics else { return }
            lastMetrics = metrics
            onChange(metrics)
        }
    }
}
