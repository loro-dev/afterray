import AfterRayRecall
import SwiftUI

/// Presents the local-computation dashboard inside the overlay, the same way
/// Settings is presented.
///
/// Two entry points open it: the overlay's chrome button and the menu-bar item.
/// The menu bar is where someone goes when they want their GPU back without
/// opening a full-screen recall surface — but menu-bar space is scarce and the
/// icon is often hidden behind the notch or another app's items, so the overlay
/// carries a visible copy that cannot be crowded out.
@MainActor
final class ComputeActivityController: ObservableObject {
    static let shared = ComputeActivityController()

    @Published private(set) var isPresented = false

    var model: ComputeActivityModel { AfterRayServices.shared.compute }

    func show() {
        isPresented = true
        if !RecallOverlayController.shared.isVisible {
            RecallOverlayController.shared.show()
        }
        // No explicit refresh: the panel's own `startWatching` polls immediately.
        // Two reports milliseconds apart also made the first CPU percentages
        // noise, since they were sampled over that gap.
    }

    func hide() {
        isPresented = false
    }

    func toggle() {
        if isPresented { hide() } else { show() }
    }
}

/// The panel as the overlay hosts it: dimmed backdrop, click-outside to close.
struct ComputeActivityOverlay: View {
    @ObservedObject var model: ComputeActivityModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            ComputeActivityPanel(model: model, onClose: onClose)
                // Under the chrome cluster it was opened from, so the panel
                // reads as belonging to that button.
                .padding(.top, 64)
                .padding(.trailing, 18)
                // The panel scrolls, so it needs the fence: without it the
                // overlay's global scroll monitor eats its gesture phases.
                .background(ScrollFenceView())
        }
    }
}
