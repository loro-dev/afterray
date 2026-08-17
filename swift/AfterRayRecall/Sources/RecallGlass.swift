import SwiftUI

public extension View {
    /// Liquid Glass on macOS 26+, material fallback on earlier systems.
    @ViewBuilder
    func recallGlass(in shape: RecallGlassShape) -> some View {
        if #available(macOS 26.0, *) {
            switch shape {
            case .circle:
                glassEffect(.regular.interactive(), in: Circle())
            case .capsule:
                glassEffect(.regular.interactive(), in: Capsule())
            case .rounded(let radius):
                glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
            }
        } else {
            recallGlassFallback(in: shape)
        }
    }
}

public struct RecallGlassCluster<Content: View>: View {
    @ViewBuilder public var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

public enum RecallGlassShape: Equatable, Sendable {
    case circle
    case capsule
    case rounded(CGFloat)
}

public struct RecallChromeIconButton: View {
    let symbol: String
    let help: String
    var tint: Color
    let action: () -> Void

    public init(
        symbol: String,
        help: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(
                    width: RecallGeometry.overlayChromeButtonSize,
                    height: RecallGeometry.overlayChromeButtonSize
                )
                .contentShape(Circle())
                .recallHoverFill(in: Circle())
        }
        .buttonStyle(RecallGlassPressStyle())
        .recallGlass(in: .circle)
        .help(help)
    }
}

/// A faint fill that appears on hover so icon-only chrome reads as clickable.
/// Color change stays even when Reduce Motion is on; the fade is short.
public struct RecallHoverFill: ViewModifier {
    let shape: AnyShape
    @State private var isHovering = false

    public func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.white.opacity(isHovering ? 0.16 : 0))
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

public extension View {
    func recallHoverFill<S: Shape>(in shape: S) -> some View {
        modifier(RecallHoverFill(shape: AnyShape(shape)))
    }
}

public struct RecallGlassPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func recallGlassFallback(in shape: RecallGlassShape) -> some View {
        switch shape {
        case .circle:
            background(.ultraThinMaterial, in: Circle())
                .background(.black.opacity(0.22), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 1) }
        case .capsule:
            background(.ultraThinMaterial, in: Capsule())
                .background(.black.opacity(0.22), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
        case .rounded(let radius):
            let rect = RoundedRectangle(cornerRadius: radius, style: .continuous)
            background(.ultraThinMaterial, in: rect)
                .background(.black.opacity(0.28), in: rect)
                .overlay { rect.stroke(.white.opacity(0.14), lineWidth: 1) }
        }
    }
}
