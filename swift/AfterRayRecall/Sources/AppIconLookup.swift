import AppKit

/// Both halves of an app icon lookup — resolving the bundle id to a URL and
/// reading the icon — go through Launch Services and the disk. Uncached,
/// every rendered timeline segment repeated both on every frame of a scroll.
/// Shared by the timeline segments and the history panel's icon strips.
public enum AppIconLookup {
    private static let cache = NSCache<NSString, NSImage>()
    private static let resolver = Resolver()
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
        return await resolver.icon(bundleIdentifier: bundleIdentifier)
    }

    /// Serializes cache misses per bundle. A stress viewport can contain
    /// hundreds of segments but only a handful of apps; without this, every
    /// segment launched the same Launch Services lookup concurrently.
    private actor Resolver {
        private var inFlight: [String: Task<NSImage?, Never>] = [:]

        func icon(bundleIdentifier: String) async -> NSImage? {
            if let hit = AppIconLookup.cachedIcon(bundleIdentifier: bundleIdentifier) {
                return hit
            }
            if let existing = inFlight[bundleIdentifier] {
                return await existing.value
            }
            let task = Task.detached(priority: .utility) {
                AppIconLookup.icon(bundleIdentifier: bundleIdentifier)
            }
            inFlight[bundleIdentifier] = task
            let icon = await task.value
            inFlight[bundleIdentifier] = nil
            return icon
        }
    }
}
