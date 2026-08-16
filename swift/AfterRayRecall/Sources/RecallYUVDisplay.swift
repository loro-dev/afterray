import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import SwiftUI
import VideoToolbox

final class ArtifactViewAttachment {
    weak var view: ArtifactLayerView?
}

struct ArtifactYUVView: NSViewRepresentable {
    var frame: RecallDisplayFrame?
    /// When false, SwiftUI must not touch layer opacity. The still player
    /// ramps it directly so parent rerenders cannot replay a stale value.
    var bindsOpacity: Bool = true
    var contentOpacity: CGFloat = 1
    var attachment: ArtifactViewAttachment?

    func makeNSView(context: Context) -> ArtifactLayerView {
        let view = ArtifactLayerView()
        attachment?.view = view
        return view
    }

    func updateNSView(_ view: ArtifactLayerView, context: Context) {
        attachment?.view = view
        guard bindsOpacity else { return }
        let frameID = frame.map { ObjectIdentifier($0) }
        if context.coordinator.frameID != frameID {
            view.setContentOpacity(0)
            context.coordinator.frameID = frameID
        }
        view.display(frame)
        view.setContentOpacity(contentOpacity)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var frameID: ObjectIdentifier?
    }
}

final class ArtifactLayerView: NSView {
    private static let opacityAnimationKey = "afterray.content-opacity"
    private var displayedFrame: RecallDisplayFrame?

    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        // Clear, not black: a newly mounted or flushed layer must not punch a
        // black hole through the still underneath while the next sample lands.
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        layer.preventsDisplaySleepDuringVideoPlayback = false
        return layer
    }

    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let displayedFrame else { return }
        self.displayedFrame = nil
        display(displayedFrame)
    }

    func setContentOpacity(_ value: CGFloat) {
        let opacity = Float(min(max(value, 0), 1))
        guard let layer, layer.opacity != opacity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.opacityAnimationKey)
        layer.opacity = opacity
        CATransaction.commit()
    }

    /// Runs entirely on Core Animation's render server. The old async loop
    /// woke the main actor every 8 ms, directly competing with a 120 Hz scrub.
    func animateContentOpacity(
        to value: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let layer else { return }
        let target = Float(min(max(value, 0), 1))
        let start = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        guard duration > 0, start != target else {
            layer.removeAnimation(forKey: Self.opacityAnimationKey)
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = timingFunction
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: Self.opacityAnimationKey)
    }

    func display(_ frame: RecallDisplayFrame?) {
        guard let frame else {
            clearDisplayedContent()
            return
        }
        guard let sample = RecallSampleBuffer.makeDisplayImmediately(from: frame) else {
            return
        }
        displayedFrame = frame
        enqueue(sample)
    }

    func clearDisplayedContent() {
        displayedFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: Self.opacityAnimationKey)
        videoRenderer?.flush()
        layer?.opacity = 0
        CATransaction.commit()
    }

    private var videoRenderer: AVSampleBufferVideoRenderer? {
        (layer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        guard let renderer = videoRenderer else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding
            || !renderer.isReadyForMoreMediaData
        {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }
}

enum RecallSampleBuffer {
    static func makeDisplayImmediately(from frame: RecallDisplayFrame?) -> CMSampleBuffer? {
        guard let frame else { return nil }
        if let buffer = frame.pixelBuffer {
            return makeDisplayImmediately(from: buffer)
        }
        guard let image = frame.fallbackImage, let buffer = pixelBuffer(from: image) else {
            return nil
        }
        return makeDisplayImmediately(from: buffer)
    }

    static func makeDisplayImmediately(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return nil }
        markDisplayImmediately(sample)
        return sample
    }

    static func hasDisplayImmediately(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
        else { return false }
        return attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true
    }

    private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: true
            )
        else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

final class RecallDisplayFrame: NSObject {
    let pixelBuffer: CVPixelBuffer?
    let fallbackImage: CGImage?

    init(pixelBuffer: CVPixelBuffer? = nil, fallbackImage: CGImage? = nil) {
        self.pixelBuffer = pixelBuffer
        self.fallbackImage = fallbackImage
    }

    /// Source pixel dimensions, needed to map OCR boxes back onto the letterboxed
    /// picture. `.zero` when the frame carries no decoded image.
    var pixelSize: CGSize {
        if let pixelBuffer {
            return CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        if let fallbackImage {
            return CGSize(width: fallbackImage.width, height: fallbackImage.height)
        }
        return .zero
    }

    var cost: Int {
        if let pixelBuffer {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            return max(width * height * 3 / 2, 1)
        }
        if let fallbackImage {
            return max(fallbackImage.width * fallbackImage.height * 4, 1)
        }
        return 1
    }
}

enum RecallFrameDecoder {
    static func decode(_ data: Data) -> RecallDisplayFrame? {
        if isIVF(data) {
            // DKIF must fail closed. ImageIO will not decode AV1 and must
            // never see an IVF payload.
            guard let buffer = RecallAV1Decoder.shared.decode(data) else { return nil }
            return RecallDisplayFrame(pixelBuffer: buffer)
        }
        if isJPEG(data), let buffer = RecallJPEGDecoder.shared.decode(data) {
            return RecallDisplayFrame(pixelBuffer: buffer)
        }
        guard let image = decodeWithImageIO(data) else { return nil }
        return RecallDisplayFrame(fallbackImage: image)
    }

    static func isIVF(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0x44, 0x4B, 0x49, 0x46])
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xFF
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(data as CFData, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        let size = (width.intValue, height.intValue)
        guard size.0 > 0, size.1 > 0 else { return nil }
        return size
    }

    static func decodeWithImageIO(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

final class RecallJPEGDecoder: @unchecked Sendable {
    static let shared = RecallJPEGDecoder()

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sessionWidth = 0
    private var sessionHeight = 0

    func decode(_ data: Data) -> CVPixelBuffer? {
        guard let size = RecallFrameDecoder.pixelSize(of: data) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard prepareSession(width: size.width, height: size.height) else { return nil }
        return decodeLocked(data)
    }

    private func prepareSession(width: Int, height: Int) -> Bool {
        if session != nil, sessionWidth == width, sessionHeight == height {
            return true
        }
        invalidate()
        let formats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        for pixelFormat in formats {
            if let created = makeSession(width: width, height: height, pixelFormat: pixelFormat) {
                session = created.session
                format = created.format
                sessionWidth = width
                sessionHeight = height
                return true
            }
        }
        return false
    }

    private func makeSession(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> (session: VTDecompressionSession, format: CMVideoFormatDescription)? {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else { return nil }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return nil }
        return (session, format)
    }

    private func decodeLocked(_ data: Data) -> CVPixelBuffer? {
        guard let session, let format else { return nil }

        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard createStatus == noErr, let block else { return nil }

        let replaceStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return nil }

        var imageBuffer: CVImageBuffer?
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { status, _, buffer, _, _ in
            if status == noErr {
                imageBuffer = buffer
            }
        }
        guard decodeStatus == noErr else { return nil }
        return imageBuffer
    }

    private func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        sessionWidth = 0
        sessionHeight = 0
    }
}

final class RecallAV1Decoder: @unchecked Sendable {
    static let shared = RecallAV1Decoder()
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sessionConfiguration: SessionConfiguration?
    private(set) var sessionCreationCount = 0

    func decode(_ data: Data) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let ivf = parseIVF(data), ivf.width > 0, ivf.height > 0, !ivf.frames.isEmpty else {
            return nil
        }
        guard prepare(ivf: ivf) else { return nil }
        var decoded: CVPixelBuffer?
        for frame in ivf.frames {
            let sampleData = stripTemporalDelimiters(frame)
            guard
                let format,
                let sample = makeSample(sampleData, format: format)
            else { return decoded }
            var imageBuffer: CVImageBuffer?
            let status = VTDecompressionSessionDecodeFrame(
                session!,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil
            ) { decodeStatus, _, buffer, _, _ in
                if decodeStatus == noErr { imageBuffer = buffer }
            }
            guard status == noErr else { return decoded }
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session!)
            if let imageBuffer { decoded = imageBuffer }
        }
        return decoded
    }

    private func prepare(ivf: ParsedIVF) -> Bool {
        guard let av1c = makeAv1C(from: ivf.frames[0]) else { return false }
        let configuration = SessionConfiguration(
            width: ivf.width,
            height: ivf.height,
            av1c: av1c
        )
        // GOPs produced by one capture stream normally share this exact
        // configuration. Their first frame is a keyframe, so VideoToolbox can
        // accept the next independent GOP without rebuilding its session.
        if session != nil, sessionConfiguration == configuration, format != nil {
            return true
        }
        let atoms: [String: Data] = ["av1C": av1c]
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
        ]
        var formatOut: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: 0x6176_3031,
            width: Int32(ivf.width),
            height: Int32(ivf.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatOut
        )
        guard formatStatus == noErr, let formatOut else { return false }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = formatOut
        sessionConfiguration = nil
        let pixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        for pixelFormat in pixelFormats {
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatOut,
                decoderSpecification: [
                    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
                ] as CFDictionary,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                ] as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &created
            )
            if status == noErr, let created {
                session = created
                sessionConfiguration = configuration
                sessionCreationCount += 1
                return true
            }
        }
        return false
    }

    private struct SessionConfiguration: Equatable {
        let width: Int
        let height: Int
        let av1c: Data
    }
}

private struct ParsedIVF {
    let width: Int
    let height: Int
    let frames: [Data]
}

private func parseIVF(_ data: Data) -> ParsedIVF? {
    guard data.count >= 32, data.starts(with: Data("DKIF".utf8)) else { return nil }
    let width = Int(data[12]) | (Int(data[13]) << 8)
    let height = Int(data[14]) | (Int(data[15]) << 8)
    var frames: [Data] = []
    var offset = 32
    while offset + 12 <= data.count {
        let size = Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
        let start = offset + 12
        let end = start + size
        guard end <= data.count else { return nil }
        frames.append(data.subdata(in: start..<end))
        offset = end
    }
    return ParsedIVF(width: width, height: height, frames: frames)
}

private func makeAv1C(from firstFrame: Data) -> Data? {
    let obus = parseOBUs(firstFrame)
    guard let seq = obus.first(where: { $0.type == 1 }) else { return nil }
    let payload = [UInt8](seq.payload)
    guard let first = payload.first else { return nil }
    let profile = first >> 5
    var av1c = Data()
    av1c.append(0x81)
    av1c.append((profile << 5) | 0x00)
    av1c.append(0x0C)
    av1c.append(0x00)
    av1c.append(seq.raw)
    return av1c
}

private func stripTemporalDelimiters(_ frame: Data) -> Data {
    let obus = parseOBUs(frame)
    if obus.isEmpty { return frame }
    var out = Data()
    for obu in obus where obu.type != 2 { out.append(obu.raw) }
    return out.isEmpty ? frame : out
}

private struct ParsedOBU {
    let type: UInt8
    let raw: Data
    let payload: Data
}

private func parseOBUs(_ data: Data) -> [ParsedOBU] {
    var obus: [ParsedOBU] = []
    var i = 0
    let bytes = [UInt8](data)
    while i < bytes.count {
        let headerStart = i
        let header = bytes[i]
        i += 1
        let type = (header >> 3) & 0x0F
        if (header & 0x04) != 0 {
            guard i < bytes.count else { break }
            i += 1
        }
        let size: Int
        if (header & 0x02) != 0 {
            var value = 0
            var shift = 0
            var ok = false
            while i < bytes.count {
                let leb = bytes[i]
                i += 1
                value |= Int(leb & 0x7F) << shift
                if leb & 0x80 == 0 {
                    ok = true
                    break
                }
                shift += 7
                if shift > 28 { break }
            }
            guard ok else { break }
            size = value
        } else {
            size = bytes.count - i
        }
        guard i + size <= bytes.count else { break }
        obus.append(
            ParsedOBU(
                type: type,
                raw: Data(bytes[headerStart..<(i + size)]),
                payload: Data(bytes[i..<(i + size)])
            )
        )
        i += size
    }
    return obus
}

private func makeSample(_ data: Data, format: CMFormatDescription) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    let create = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &block
    )
    guard create == kCMBlockBufferNoErr, let block else { return nil }
    _ = data.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(
            with: raw.baseAddress!,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: data.count
        )
    }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 1),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var size = data.count
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        formatDescription: format,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &size,
        sampleBufferOut: &sample
    )
    return status == noErr ? sample : nil
}
