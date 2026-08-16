import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import XCTest
@testable import AfterRayRecall

final class RecallYUVDisplayTests: XCTestCase {
    func testJPEGMagicAndPixelSize() throws {
        let jpeg = try encodeJPEG(width: 64, height: 48, color: .red)
        XCTAssertTrue(RecallFrameDecoder.isJPEG(jpeg))
        let size = try XCTUnwrap(RecallFrameDecoder.pixelSize(of: jpeg))
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
    }

    func testJPEGDecodesToPixelBuffer() throws {
        let jpeg = try encodeJPEG(width: 128, height: 80, color: .blue)
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(jpeg))
        let buffer = try XCTUnwrap(frame.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 80)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
        XCTAssertNil(frame.fallbackImage)
    }

    func testIVFHeaderDoesNotFallThroughToImageIO() {
        let ivf = Data([0x44, 0x4B, 0x49, 0x46, 0x00, 0x00, 0x20, 0x00])
        XCTAssertTrue(RecallFrameDecoder.isIVF(ivf))
        XCTAssertFalse(RecallFrameDecoder.isJPEG(ivf))
        XCTAssertNil(RecallFrameDecoder.decode(ivf))
    }

    func testCorruptIVFDoesNotFallThroughToImageIO() {
        var ivf = Data("DKIF".utf8)
        ivf.append(contentsOf: [0, 0, 32, 0])
        ivf.append(Data(repeating: 0, count: 24))
        ivf.append(contentsOf: [4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xD8, 0xFF, 0x00])
        XCTAssertTrue(RecallFrameDecoder.isIVF(ivf))
        XCTAssertNil(RecallFrameDecoder.decode(ivf))
    }

    func testGoldenIVFDecodesThroughVideoToolbox() throws {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("golden IVF fixture not visible from the Swift test cwd")
        }
        let data = try Data(contentsOf: url)
        XCTAssertTrue(RecallFrameDecoder.isIVF(data))
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(data))
        let buffer = try XCTUnwrap(frame.pixelBuffer)
        XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 0)
        XCTAssertGreaterThan(CVPixelBufferGetHeight(buffer), 0)
    }

    func testCompatibleGopsReuseTheVideoToolboxSession() throws {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("golden IVF fixture not visible from the Swift test cwd")
        }
        let data = try Data(contentsOf: url)
        let decoder = RecallAV1Decoder()

        XCTAssertNotNil(decoder.decode(data))
        let afterFirst = decoder.sessionCreationCount
        XCTAssertNotNil(decoder.decode(data))

        XCTAssertEqual(decoder.sessionCreationCount, afterFirst)
    }

    func testNonJPEGFallsBackToImageIO() throws {
        let png = try encodePNG(width: 32, height: 24, color: .green)
        XCTAssertFalse(RecallFrameDecoder.isJPEG(png))
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(png))
        XCTAssertNil(frame.pixelBuffer)
        let image = try XCTUnwrap(frame.fallbackImage)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 24)
    }

    func testJPEGPixelBufferWrapsAsImmediateSample() throws {
        let jpeg = try encodeJPEG(width: 128, height: 80, color: .blue)
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(jpeg))
        let buffer = try XCTUnwrap(frame.pixelBuffer)
        let sample = try XCTUnwrap(RecallSampleBuffer.makeDisplayImmediately(from: buffer))
        XCTAssertTrue(RecallSampleBuffer.hasDisplayImmediately(sample))
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === buffer)
    }

    func testPNGFallbackWrapsAsImmediateSample() throws {
        let png = try encodePNG(width: 32, height: 24, color: .green)
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(png))
        let sample = try XCTUnwrap(RecallSampleBuffer.makeDisplayImmediately(from: frame))
        XCTAssertTrue(RecallSampleBuffer.hasDisplayImmediately(sample))
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 24)
    }

    func testDisplayLayerEnqueuesJPEGFrameWithoutFailing() throws {
        let jpeg = try encodeJPEG(width: 128, height: 80, color: .blue)
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(jpeg))
        let view = ArtifactLayerView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(view.layer is AVSampleBufferDisplayLayer)
        view.display(frame)
        let renderer = try XCTUnwrap((view.layer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer)
        XCTAssertNotEqual(renderer.status, .failed)
    }

    private func encodeJPEG(width: Int, height: Int, color: NSColor) throws -> Data {
        try encode(width: width, height: height, color: color, format: .jpeg, quality: 0.8)
    }

    private func encodePNG(width: Int, height: Int, color: NSColor) throws -> Data {
        try encode(width: width, height: height, color: color, format: .png, quality: 1)
    }

    private func encode(
        width: Int,
        height: Int,
        color: NSColor,
        format: NSBitmapImageRep.FileType,
        quality: Double
    ) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if format == .jpeg {
            properties[.compressionFactor] = quality
        }
        guard let data = rep.representation(using: format, properties: properties) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
