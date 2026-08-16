import AppKit
import SwiftUI

/// Both halves of an app icon lookup — resolving the bundle id to a URL and
/// reading the icon — go through Launch Services and the disk. Uncached,
/// every rendered timeline segment repeated both on every frame of a scroll.
/// Shared by the timeline segments and the history panel's icon strips.
public enum AppIconLookup {
    private static let cache = NSCache<NSString, NSImage>()
    /// Marks "looked it up, there is no icon", so a missing app does not
    /// re-query Launch Services forever.
    private static let absent = NSImage(size: .zero)

    /// Cache-only read: never touches Launch Services. Safe on any thread,
    /// safe at scroll speed.
    public static func cachedIcon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        guard let cached = cache.object(forKey: bundleIdentifier as NSString) else { return nil }
        return cached === absent ? nil : cached
    }

    public static func icon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            return cached === absent ? nil : cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            cache.setObject(absent, forKey: key)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// The miss path off the main thread: rows appearing during a scroll
    /// must not pay a Launch Services round trip on the render loop.
    public static func iconAsync(bundleIdentifier: String?) async -> NSImage? {
        if let hit = cachedIcon(bundleIdentifier: bundleIdentifier) { return hit }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            icon(bundleIdentifier: bundleIdentifier)
        }.value
    }
}

/// An app's icon by bundle id, for lists that name apps. Draws the cached icon
/// on the first frame when there is one and fills in off the main thread
/// otherwise, so a row never blocks on Launch Services. An uninstalled app —
/// or one only known from the protected-apps catalog — keeps the placeholder
/// rather than leaving a hole where every other row has a square.
public struct AppIconView: View {
    private let bundleIdentifier: String
    private let size: CGFloat
    @State private var icon: NSImage?

    public init(bundleIdentifier: String, size: CGFloat = 20) {
        self.bundleIdentifier = bundleIdentifier
        self.size = size
        _icon = State(initialValue: AppIconLookup.cachedIcon(bundleIdentifier: bundleIdentifier))
    }

    public var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.62))
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .frame(width: size, height: size)
        .task(id: bundleIdentifier) {
            let resolved = await AppIconLookup.iconAsync(bundleIdentifier: bundleIdentifier)
            if resolved !== icon { icon = resolved }
        }
    }
}
