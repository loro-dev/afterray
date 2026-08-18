import Foundation

/// OCR boxes for recently viewed frames.
///
/// Fetching them is a daemon round trip into the encrypted vault, and a scrub
/// revisits the same handful of frames constantly, so the answer is worth
/// keeping. Bounded and insertion-ordered rather than an `NSCache` because the
/// eviction has to be predictable: this holds decrypted screen text.
@MainActor
public final class OcrRegionCache {
    public static let shared = OcrRegionCache()

    private var cached: [String: [OcrRegion]] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<[OcrRegion], Never>] = [:]
    private var generation: UInt64 = 0
    private let limit = 32

    private init() {}

    func regions(momentID: String, loader: @escaping RecallOcrLoader) async -> [OcrRegion] {
        if let hit = cached[momentID] { return hit }
        if let existing = inFlight[momentID] { return await existing.value }

        let requestGeneration = generation
        let task = Task { () -> [OcrRegion] in
            // A frame with no text is a real answer, not a failure to retry:
            // most captures of a video player or a terminal splash have none.
            (try? await loader(momentID))?.regions ?? []
        }
        inFlight[momentID] = task
        let regions = await task.value
        inFlight[momentID] = nil
        // The vault was wiped from memory while this was in flight; the bytes
        // in hand are already loaded, but they must not be filed away.
        guard generation == requestGeneration else { return regions }
        store(momentID: momentID, regions: regions)
        return regions
    }

    private func store(momentID: String, regions: [OcrRegion]) {
        if cached[momentID] == nil { order.append(momentID) }
        cached[momentID] = regions
        while order.count > limit {
            cached[order.removeFirst()] = nil
        }
    }

    /// Screen text is exactly the decrypted content the app drops on lock and
    /// sleep — hooked into `AfterRayApp`'s teardown beside the image caches.
    public func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cached.removeAll()
        order.removeAll()
    }
}
