import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

public typealias RecallThumbnailLoader = @Sendable (String) async throws -> Data

/// Small decoded thumbnails for the search filmstrip.
///
/// Deliberately separate from the full-resolution still cache: a strip of two
/// dozen thumbnails must never evict the frames the recall view is about to
/// show. Thumbnails are ~360px on the long edge, so a couple hundred of them
/// cost less than one full capture.
@MainActor
public final class RecallThumbnailCache {
    public static let shared = RecallThumbnailCache()

    private let images = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var generation: UInt64 = 0

    private init() {
        images.countLimit = 240
        images.totalCostLimit = 96 * 1_024 * 1_024
    }

    public func cached(momentID: String) -> CGImage? {
        images.object(forKey: momentID as NSString)
    }

    public func image(
        momentID: String,
        loader: @escaping RecallThumbnailLoader
    ) async -> CGImage? {
        if let hit = cached(momentID: momentID) { return hit }
        if let existing = inFlight[momentID] { return await existing.value }

        let requestGeneration = generation
        let task = Task { @MainActor () -> CGImage? in
            guard let data = try? await loader(momentID) else { return nil }
            return await Task.detached(priority: .utility) {
                // The daemon serves JPEG when a thumbnail exists and raw IVF for
                // moments packed before thumbnails did. `RecallFrameDecoder`
                // already dispatches on the bytes, so both land here.
                RecallFrameDecoder.decode(data)?.makeThumbnailImage()
            }.value
        }
        inFlight[momentID] = task
        let decoded = await task.value
        inFlight[momentID] = nil
        guard generation == requestGeneration else { return decoded }
        if let decoded {
            images.setObject(
                decoded,
                forKey: momentID as NSString,
                cost: decoded.width * decoded.height * 4
            )
        }
        return decoded
    }

    /// Warms neighbours of the selection so stepping through results does not
    /// flash placeholders.
    public func prefetch(momentIDs: [String], loader: @escaping RecallThumbnailLoader) {
        for momentID in momentIDs
        where cached(momentID: momentID) == nil && inFlight[momentID] == nil {
            Task { @MainActor [weak self] in
                _ = await self?.image(momentID: momentID, loader: loader)
            }
        }
    }

    public func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        images.removeAllObjects()
    }
}

extension RecallDisplayFrame {
    /// A `CGImage` fit for a filmstrip cell, whatever the frame decoded from.
    func makeThumbnailImage() -> CGImage? {
        if let fallbackImage { return fallbackImage }
        guard let pixelBuffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }
}
