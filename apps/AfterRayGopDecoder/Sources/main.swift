import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private let av1Codec: CMVideoCodecType = 0x6176_3031 // av01
private let outputMagic = Data("ARYI4201".utf8)
private let maximumDimension = 8_192
private let maximumFrames = 30
private let maximumDecodedBytes = 1_610_612_736

private struct DecoderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct IVFFrame {
    let pts: UInt64
    let bytes: Data
}

private struct IVF {
    let width: Int
    let height: Int
    let frames: [IVFFrame]
}

private struct OBU {
    let type: UInt8
    let raw: Data
    let payload: Data
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let ivf = try parseIVF(input)
    let decoder = try AV1Decoder(ivf: ivf)
    var header = outputMagic
    header.appendLE(UInt32(ivf.width))
    header.appendLE(UInt32(ivf.height))
    header.appendLE(UInt32(ivf.frames.count))
    try FileHandle.standardOutput.write(contentsOf: header)
    for frame in ivf.frames {
        let pixels = try decoder.decode(frame)
        var prefix = Data()
        prefix.appendLE(UInt32(pixels.count))
        try FileHandle.standardOutput.write(contentsOf: prefix)
        try FileHandle.standardOutput.write(contentsOf: pixels)
    }
} catch {
    FileHandle.standardError.write(Data("afterray-gop-decoder: \(error)\n".utf8))
    exit(1)
}

private final class AV1Decoder {
    private let format: CMVideoFormatDescription
    private let session: VTDecompressionSession
    private let width: Int
    private let height: Int

    init(ivf: IVF) throws {
        guard let first = ivf.frames.first, let av1C = makeAv1C(from: first.bytes) else {
            throw DecoderError("first frame has no AV1 sequence header")
        }
        width = ivf.width
        height = ivf.height
        let atoms: [String: Data] = ["av1C": av1C]
        let formatExtensions: [CFDictionary?] = [
            [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary,
            nil,
        ]
        var acceptedSession: VTDecompressionSession?
        var acceptedFormat: CMVideoFormatDescription?
        var sessionStatus = OSStatus(-1)
        let pixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        let decoderSpecifications: [CFDictionary?] = [
            [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:
                    kCFBooleanTrue as Any,
            ] as CFDictionary,
            nil,
        ]
        for extensions in formatExtensions {
            var createdFormat: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: av1Codec,
                width: Int32(ivf.width),
                height: Int32(ivf.height),
                extensions: extensions,
                formatDescriptionOut: &createdFormat
            )
            guard formatStatus == noErr, let createdFormat else {
                sessionStatus = formatStatus
                continue
            }
            for decoderSpecification in decoderSpecifications {
                for pixelFormat in pixelFormats {
                    var createdSession: VTDecompressionSession?
                    sessionStatus = VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: createdFormat,
                        decoderSpecification: decoderSpecification,
                        imageBufferAttributes: [
                            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                            kCVPixelBufferMetalCompatibilityKey: true,
                            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                        ] as CFDictionary,
                        outputCallback: nil,
                        decompressionSessionOut: &createdSession
                    )
                    if sessionStatus == noErr, let createdSession {
                        acceptedSession = createdSession
                        acceptedFormat = createdFormat
                        break
                    }
                }
                if acceptedSession != nil { break }
            }
            if acceptedSession != nil { break }
        }
        guard let acceptedSession, let acceptedFormat else {
            let config = av1C.prefix(16).map { String($0, radix: 16) }.joined(separator: " ")
            throw DecoderError("could not create AV1 decoder: \(sessionStatus), av1C=\(config)")
        }
        format = acceptedFormat
        session = acceptedSession
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    func decode(_ frame: IVFFrame) throws -> Data {
        let sampleBytes = stripTemporalDelimiters(frame.bytes)
        let sample = try makeSample(sampleBytes, format: format, pts: frame.pts)
        var imageBuffer: CVImageBuffer?
        var callbackStatus: OSStatus = noErr
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, _, buffer, _, _ in
            callbackStatus = status
            imageBuffer = buffer
        }
        guard status == noErr else { throw DecoderError("decode submit failed: \(status)") }
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waitStatus == noErr else { throw DecoderError("decode wait failed: \(waitStatus)") }
        guard callbackStatus == noErr, let imageBuffer else {
            throw DecoderError("decode callback failed: \(callbackStatus)")
        }
        return try copyI420(from: imageBuffer, width: width, height: height)
    }
}

private func parseIVF(_ data: Data) throws -> IVF {
    guard data.count >= 32, data.starts(with: Data("DKIF".utf8)) else {
        throw DecoderError("input is not IVF")
    }
    let width = Int(readU16(data, at: 12))
    let height = Int(readU16(data, at: 14))
    guard width >= 16,
          height >= 16,
          width <= maximumDimension,
          height <= maximumDimension,
          width.isMultiple(of: 2),
          height.isMultiple(of: 2)
    else {
        throw DecoderError("invalid dimensions \(width)x\(height)")
    }
    var frames: [IVFFrame] = []
    var offset = 32
    while offset + 12 <= data.count {
        let count = Int(readU32(data, at: offset))
        let pts = readU64(data, at: offset + 4)
        let start = offset + 12
        let end = start + count
        guard count > 0, end <= data.count else { throw DecoderError("truncated IVF frame") }
        frames.append(IVFFrame(pts: pts, bytes: data.subdata(in: start ..< end)))
        guard frames.count <= maximumFrames else { throw DecoderError("too many IVF frames") }
        offset = end
    }
    guard !frames.isEmpty, offset == data.count else { throw DecoderError("invalid IVF frame table") }
    let frameBytes = width * height * 3 / 2
    guard frameBytes <= maximumDecodedBytes / frames.count else {
        throw DecoderError("decoded GOP exceeds the maintenance memory budget")
    }
    return IVF(width: width, height: height, frames: frames)
}

private func parseOBUs(_ data: Data) -> [OBU] {
    let bytes = [UInt8](data)
    var result: [OBU] = []
    var cursor = 0
    while cursor < bytes.count {
        let headerStart = cursor
        let header = bytes[cursor]
        cursor += 1
        let type = (header >> 3) & 0x0F
        if header & 0x04 != 0 {
            guard cursor < bytes.count else { return [] }
            cursor += 1
        }
        let size: Int
        if header & 0x02 != 0 {
            var value = 0
            var shift = 0
            var complete = false
            while cursor < bytes.count, shift <= 28 {
                let byte = bytes[cursor]
                cursor += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    complete = true
                    break
                }
                shift += 7
            }
            guard complete else { return [] }
            size = value
        } else {
            size = bytes.count - cursor
        }
        guard size >= 0, cursor + size <= bytes.count else { return [] }
        let payload = Data(bytes[cursor ..< cursor + size])
        let raw = Data(bytes[headerStart ..< cursor + size])
        result.append(OBU(type: type, raw: raw, payload: payload))
        cursor += size
    }
    return result
}

private func makeAv1C(from frame: Data) -> Data? {
    guard let sequence = parseOBUs(frame).first(where: { $0.type == 1 }),
          let first = sequence.payload.first
    else { return nil }
    let profile = first >> 5
    var result = Data([
        0x81,
        profile << 5,
        0x0C,
        0x00,
    ])
    result.append(sequence.raw)
    return result
}

private func stripTemporalDelimiters(_ frame: Data) -> Data {
    let obus = parseOBUs(frame)
    guard !obus.isEmpty else { return frame }
    return obus.filter { $0.type != 2 }.reduce(into: Data()) { $0.append($1.raw) }
}

private func makeSample(
    _ data: Data,
    format: CMFormatDescription,
    pts: UInt64
) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
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
    guard blockStatus == noErr, let block else { throw DecoderError("block allocation failed") }
    let copyStatus = data.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return OSStatus(-1) }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: data.count
        )
    }
    guard copyStatus == noErr else { throw DecoderError("block copy failed") }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 1),
        presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1),
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
    guard sampleStatus == noErr, let sample else { throw DecoderError("sample creation failed") }
    return sample
}

private func copyI420(from buffer: CVPixelBuffer, width: Int, height: Int) throws -> Data {
    guard CVPixelBufferGetPlaneCount(buffer) == 2 else { throw DecoderError("decoder did not return NV12") }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        throw DecoderError("pixel buffer has no planes")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    var result = Data(capacity: width * height * 3 / 2)
    for row in 0 ..< height {
        result.append(yBase.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self), count: width)
    }
    for component in 0 ..< 2 {
        for row in 0 ..< height / 2 {
            let source = uvBase.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width / 2 {
                result.append(source[column * 2 + component])
            }
        }
    }
    return result
}

private func readU16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func readU32(_ data: Data, at offset: Int) -> UInt32 {
    (0 ..< 4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
}

private func readU64(_ data: Data, at offset: Int) -> UInt64 {
    (0 ..< 8).reduce(0) { $0 | UInt64(data[offset + $1]) << UInt64(8 * $1) }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
