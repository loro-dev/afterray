import CoreGraphics
import Foundation
import ImageIO

/// Bytes for a chat-card preview. Separate from the filmstrip loader so a
/// 360px `ReadThumbnail` JPEG never becomes the only source for a ~440pt card.
public typealias RecallChatPreviewLoader = (String) async throws -> Data

/// `MomentGet` metadata for the citation time label.
public typealias RecallMomentLoader = (String) async throws -> RecallMoment

/// Decoded chat-preview stills. Kept off `RecallThumbnailCache` so a strip of
/// filmstrip JPEGs cannot evict (or be evicted by) these larger frames.
@MainActor
public final class RecallChatPreviewCache {
    public static let shared = RecallChatPreviewCache()

    /// Long edge stored and drawn. ~440pt @2x plus a little headroom; larger
    /// stills are downscaled here so the cache never holds 4K RGBA.
    public static let maxEdge = 1280

    private let images = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var generation: UInt64 = 0

    private init() {
        images.countLimit = 32
        images.totalCostLimit = 80 * 1_024 * 1_024
    }

    public func cached(momentID: String) -> CGImage? {
        images.object(forKey: momentID as NSString)
    }

    public func image(
        momentID: String,
        loader: @escaping RecallChatPreviewLoader
    ) async -> CGImage? {
        if let hit = cached(momentID: momentID) { return hit }
        if let existing = inFlight[momentID] { return await existing.value }

        let requestGeneration = generation
        let task = Task { @MainActor () -> CGImage? in
            guard let data = try? await loader(momentID) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                RecallChatPreviewDecoder.decode(data, maxEdge: Self.maxEdge)
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

    public func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        images.removeAllObjects()
    }
}

enum RecallChatPreviewDecoder {
    static func decode(_ data: Data, maxEdge: Int) -> CGImage? {
        if RecallFrameDecoder.isIVF(data) {
            return RecallFrameDecoder.decode(data)?
                .makeThumbnailImage()?
                .scaledToLongEdge(maxEdge)
        }
        if let image = decodeImageIOThumbnail(data, maxEdge: maxEdge) {
            return image
        }
        return RecallFrameDecoder.decode(data)?
            .makeThumbnailImage()?
            .scaledToLongEdge(maxEdge)
    }

    private static func decodeImageIOThumbnail(_ data: Data, maxEdge: Int) -> CGImage? {
        guard maxEdge > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return image
    }
}

extension CGImage {
    func scaledToLongEdge(_ maxEdge: Int) -> CGImage {
        let longEdge = max(width, height)
        guard maxEdge > 0, longEdge > maxEdge else { return self }
        let scale = CGFloat(maxEdge) / CGFloat(longEdge)
        let newWidth = max(Int((CGFloat(width) * scale).rounded()), 1)
        let newHeight = max(Int((CGFloat(height) * scale).rounded()), 1)
        let colorSpace = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = bitmapInfo.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) ?? CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? self
    }
}
