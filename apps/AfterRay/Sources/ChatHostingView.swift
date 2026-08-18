import AppKit
import SwiftUI

/// Full-size content is drawn underneath the transparent native titlebar.
/// AppKit otherwise treats mouse-downs in that strip as window dragging before
/// SwiftUI can deliver hover and click events to the custom header controls.
final class ChatHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
