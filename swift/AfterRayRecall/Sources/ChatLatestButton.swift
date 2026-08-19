import SwiftUI

struct ChatLatestButton: View {
    @Environment(\.afterRayCopy) private var copy
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? ChatPalette.label : ChatPalette.secondary)
                .frame(width: 32, height: 32)
                .background(
                    Color.white.opacity(isHovering ? 0.12 : 0.07),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(isHovering ? 0.18 : 0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(copy.chat.goToLatest)
        .accessibilityLabel(copy.chat.goToLatest)
        .accessibilityIdentifier("chat-jump-to-latest")
    }
}
