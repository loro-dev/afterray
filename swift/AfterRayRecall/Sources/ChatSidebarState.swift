import SwiftUI

/// Shared window chrome state. The shipped app's native toolbar and the
/// reusable SwiftUI chat surface must always agree about sidebar visibility.
@MainActor
public final class ChatSidebarState: ObservableObject {
    public nonisolated static let expandedWidth: CGFloat = 228

    @Published public var isCollapsed: Bool

    public init(isCollapsed: Bool = false) {
        self.isCollapsed = isCollapsed
    }
}
