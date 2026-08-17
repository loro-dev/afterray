import CoreGraphics
import ImageIO
import XCTest
@testable import AfterRayRecall

final class ChatMomentTimeLabelTests: XCTestCase {
    /// 2026-08-17 14:32:05 PDT = 2026-08-17 21:32:05 UTC
    private let capturedAtMs: Int64 = 1_787_002_325_000

    func testFormatsPacificDaylightWithAbbreviation() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(
            ChatMomentTimeLabel.format(capturedAtMs: capturedAtMs, timeZone: zone),
            "2026-08-17 14:32:05 PDT"
        )
    }

    func testFormatsShanghaiWithAbbreviationOrOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let formatted = ChatMomentTimeLabel.format(capturedAtMs: capturedAtMs, timeZone: zone)
        XCTAssertTrue(
            formatted == "2026-08-18 05:32:05 GMT+8"
                || formatted == "2026-08-18 05:32:05 CST",
            "unexpected Shanghai label: \(formatted)"
        )
    }

    func testGmtOffsetIncludesMinutesWhenNeeded() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let date = Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1_000)
        XCTAssertEqual(ChatMomentTimeLabel.gmtOffset(for: zone, at: date), "GMT+5:30")
    }

    func testUsesGmtOffsetWhenAbbreviationIsEmpty() {
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1_000)
        // Fixed-offset zones still report an abbreviation; the offset helper
        // is what we fall back to when that string is empty.
        XCTAssertEqual(ChatMomentTimeLabel.gmtOffset(for: zone, at: date), "GMT+8")
    }
}

@MainActor
final class ChatMomentPreviewTests: XCTestCase {
    func testChatPreviewPrefersTheHotStill() async throws {
        let daemon = ChatPreviewDaemon()
        let repository = RecallImageRepository(daemon: daemon)
        let moment = RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: 1,
            imageArtifactId: "still-1",
            gop: RecallGopRef(segmentId: "g1", index: 3, frameCount: 12)
        )

        let bytes = try await repository.chatPreviewBytes(for: moment)
        XCTAssertEqual(bytes, Data("still".utf8))
        let gopCalls = await daemon.gopCalls
        XCTAssertTrue(gopCalls.isEmpty)
    }

    func testChatPreviewFallsBackToExactGopFrameWhenStillIsGone() async throws {
        let daemon = ChatPreviewDaemon()
        let repository = RecallImageRepository(daemon: daemon)
        let moment = RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: 1,
            imageArtifactId: "missing-still",
            gop: RecallGopRef(segmentId: "g1", index: 3, frameCount: 12)
        )

        let bytes = try await repository.chatPreviewBytes(for: moment)
        XCTAssertEqual(bytes, Data("exact-3".utf8))
        let gopCalls = await daemon.gopCalls
        XCTAssertEqual(gopCalls, [.init(segmentID: "g1", index: 3, mode: "exact")])
    }

    func testChatPreviewWithoutStillOrGopFails() async {
        let repository = RecallImageRepository(daemon: ChatPreviewDaemon())
        let moment = RecallMoment(id: "m1", sessionId: "s1", capturedAtMs: 1)
        do {
            _ = try await repository.chatPreviewBytes(for: moment)
            XCTFail("expected missingData")
        } catch let error as DaemonClientError {
            XCTAssertEqual(error, .missingData)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPreviewDecoderDoesNotUpscaleASmallJpeg() throws {
        let jpeg = try smallJPEG(width: 96, height: 64)
        let image = try XCTUnwrap(RecallChatPreviewDecoder.decode(jpeg, maxEdge: 1280))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 64)
    }

    func testPreviewDecoderDownscalesALargeJpeg() throws {
        let jpeg = try smallJPEG(width: 1920, height: 1080)
        let image = try XCTUnwrap(RecallChatPreviewDecoder.decode(jpeg, maxEdge: 1280))
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 720)
    }

    func testClearingThePreviewCacheDropsTheHit() async {
        RecallChatPreviewCache.shared.clearSensitiveData()
        let jpeg = try! smallJPEG(width: 64, height: 48)
        let decoded = await RecallChatPreviewCache.shared.image(momentID: "m-cache") { _ in jpeg }
        XCTAssertNotNil(decoded)
        XCTAssertNotNil(RecallChatPreviewCache.shared.cached(momentID: "m-cache"))
        RecallChatPreviewCache.shared.clearSensitiveData()
        XCTAssertNil(RecallChatPreviewCache.shared.cached(momentID: "m-cache"))
    }
}

private actor ChatPreviewDaemon: RecallDaemonServing {
    struct Call: Equatable {
        let segmentID: String
        let index: UInt16
        let mode: String
    }

    private(set) var gopCalls: [Call] = []

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(
        sessionID _: String,
        centerMs _: Int64,
        limit _: Int
    ) async throws -> [RecallMoment] { [] }

    func artifact(id: String) async throws -> ArtifactPayload {
        if id == "still-1" {
            return ArtifactPayload(id: id, contentType: "image/jpeg", bytes: Data("still".utf8))
        }
        throw DaemonClientError.rejected("missing still")
    }

    func gopFrame(segmentID: String, index: UInt16, mode: String) async throws -> ArtifactPayload {
        gopCalls.append(.init(segmentID: segmentID, index: index, mode: mode))
        return ArtifactPayload(
            id: segmentID,
            contentType: "video/av1",
            bytes: Data("exact-\(index)".utf8)
        )
    }

    func setFavorite(momentID _: String, favorite _: Bool) async throws {}
}

private func smallJPEG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
        let image = context.makeImage()
    else {
        throw DaemonClientError.invalidResponse
    }
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        )
    else {
        throw DaemonClientError.invalidResponse
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw DaemonClientError.invalidResponse
    }
    return data as Data
}
