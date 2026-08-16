@testable import AfterRayRecall
import XCTest

final class ModelDownloadQueueTests: XCTestCase {
    private func pack(
        _ id: String,
        name: String,
        expected: UInt64,
        present: Bool = false
    ) -> ModelPack {
        ModelPack(
            id: id,
            name: name,
            capability: "test",
            path: "/tmp/\(id)",
            present: present,
            bytes: present ? expected : 0,
            required: true,
            expectedBytes: expected
        )
    }

    private func library(_ download: ModelDownloadProgress?) -> ModelLibrary {
        ModelLibrary(
            directory: "/tmp/models",
            packs: [
                pack("asr", name: "Qwen3 ASR", expected: 4_000_000_000),
                pack("embedding", name: "Text embeddings", expected: 100_000_000),
                pack("llm", name: "Qwen3.5 9B", expected: 6_000_000_000),
            ],
            download: download
        )
    }

    func testIdleLibraryHasAnEmptyQueue() {
        XCTAssertTrue(library(nil).downloadQueue().isEmpty)
    }

    /// A pack that finished is not queue material — the daemon briefly reports
    /// `ready` before clearing the slot, and a "Ready" row with a Cancel button
    /// would be nonsense.
    func testSettledStatesDoNotProduceARow() {
        for state: ModelPackState in [.ready, .inUse, .notDownloaded, .incompatible] {
            let progress = ModelDownloadProgress(
                packId: "asr",
                state: state,
                bytes: 10,
                expectedBytes: 100
            )
            XCTAssertTrue(
                library(progress).downloadQueue().isEmpty,
                "\(state) should not appear in the queue"
            )
        }
    }

    func testActivePackLeadsAndWaitingPacksFollowInOrder() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            queuedPackIds: ["embedding", "llm"],
            state: .downloading,
            bytes: 1_000_000_000,
            expectedBytes: 4_000_000_000
        )
        let queue = library(progress).downloadQueue()

        XCTAssertEqual(queue.map(\.id), ["asr", "embedding", "llm"])
        XCTAssertEqual(queue.map(\.stage), [.downloading, .waiting, .waiting])
        XCTAssertEqual(queue[0].name, "Qwen3 ASR")
        XCTAssertEqual(queue[0].percent, 25)
        XCTAssertTrue(queue[0].isRunning)
        XCTAssertTrue(queue[0].canPause)
        XCTAssertFalse(queue[1].isRunning)
        XCTAssertFalse(queue[1].canPause)
        // Waiting rows borrow the pack's expected size, which the daemon only
        // reports for whatever is transferring right now.
        XCTAssertEqual(queue[1].expectedBytes, 100_000_000)
    }

    /// A waiting pack's ETA has to include everything ahead of it, because the
    /// daemon runs one transfer at a time.
    func testWaitingEtaAccumulatesEverythingAheadOfIt() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            queuedPackIds: ["embedding", "llm"],
            state: .downloading,
            bytes: 3_000_000_000,
            expectedBytes: 4_000_000_000
        )
        let queue = library(progress).downloadQueue(bytesPerSecond: 1_000_000)

        // 1 GB left on the active pack.
        XCTAssertEqual(try XCTUnwrap(queue[0].etaSeconds), 1_000, accuracy: 1)
        // ...plus the 100 MB embedding pack.
        XCTAssertEqual(try XCTUnwrap(queue[1].etaSeconds), 1_100, accuracy: 1)
        // ...plus the 6 GB assistant pack.
        XCTAssertEqual(try XCTUnwrap(queue[2].etaSeconds), 7_100, accuracy: 1)
    }

    func testEtaIsWithheldWithoutAMeasuredRate() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            queuedPackIds: ["embedding"],
            state: .downloading,
            bytes: 1,
            expectedBytes: 4_000_000_000
        )
        for rate: Double? in [nil, 0, -1] {
            let queue = library(progress).downloadQueue(bytesPerSecond: rate)
            XCTAssertNil(queue[0].etaSeconds)
            XCTAssertNil(queue[0].etaText)
            XCTAssertNil(queue[1].etaSeconds)
        }
    }

    /// Verifying reads no bytes off the network and pausing stops the clock, so
    /// projecting the last-known rate onto either would invent a countdown.
    func testVerifyingAndPausedCarryNoEta() {
        for state: ModelPackState in [.verifying, .paused] {
            let progress = ModelDownloadProgress(
                packId: "asr",
                state: state,
                bytes: 1_000_000_000,
                expectedBytes: 4_000_000_000
            )
            let item = library(progress).downloadQueue(bytesPerSecond: 1_000_000)[0]
            XCTAssertNil(item.etaSeconds, "\(state) should not project an ETA")
            XCTAssertEqual(item.percent, 25, "\(state) still shows how far it got")
        }
        let paused = ModelDownloadProgress(
            packId: "asr",
            state: .paused,
            bytes: 1,
            expectedBytes: 4
        )
        let item = library(paused).downloadQueue()[0]
        XCTAssertTrue(item.canResume)
        XCTAssertFalse(item.canPause)
    }

    func testFailedRowKeepsItsErrorAndOffersARetry() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            state: .failed,
            bytes: 12,
            expectedBytes: 100,
            error: "not enough free space"
        )
        let item = library(progress).downloadQueue()[0]

        XCTAssertEqual(item.stage, .failed)
        XCTAssertEqual(item.error, "not enough free space")
        XCTAssertTrue(item.canRetry)
        XCTAssertFalse(item.isRunning)
        XCTAssertFalse(item.canPause)
    }

    /// `isQueued` is what disables a pack's Download and Remove buttons. It has
    /// to answer for waiting packs too, not just the one transferring.
    func testIsQueuedCoversActiveAndWaitingPacksOnly() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            queuedPackIds: ["embedding"],
            state: .downloading,
            bytes: 1,
            expectedBytes: 100
        )
        let live = library(progress)
        XCTAssertTrue(live.isQueued(packID: "asr"))
        XCTAssertTrue(live.isQueued(packID: "embedding"))
        XCTAssertFalse(live.isQueued(packID: "llm"))
        XCTAssertFalse(library(nil).isQueued(packID: "asr"))

        let settled = ModelDownloadProgress(
            packId: "asr",
            state: .ready,
            bytes: 100,
            expectedBytes: 100
        )
        XCTAssertFalse(library(settled).isQueued(packID: "asr"))
    }

    func testUnknownPackFallsBackToItsIdRatherThanVanishing() {
        let progress = ModelDownloadProgress(
            packId: "asr",
            queuedPackIds: ["retired-pack"],
            state: .downloading,
            bytes: 1,
            expectedBytes: 100
        )
        let queue = library(progress).downloadQueue(bytesPerSecond: 1_000)

        XCTAssertEqual(queue.map(\.id), ["asr", "retired-pack"])
        XCTAssertEqual(queue[1].name, "retired-pack")
        XCTAssertNil(queue[1].expectedBytes)
        XCTAssertNil(queue[1].etaSeconds, "an unknown size cannot be projected")
    }

    func testDurationTextStaysCoarse() {
        XCTAssertEqual(ModelDownloadQueueItem.durationText(3), "a few seconds")
        XCTAssertEqual(ModelDownloadQueueItem.durationText(42), "42 sec")
        XCTAssertEqual(ModelDownloadQueueItem.durationText(61), "about a minute")
        XCTAssertEqual(ModelDownloadQueueItem.durationText(400), "7 min")
        XCTAssertEqual(ModelDownloadQueueItem.durationText(3_600), "1 hr")
        XCTAssertEqual(ModelDownloadQueueItem.durationText(5_400), "1 hr 30 min")
    }

    func testSizeTextShowsProgressOnlyOncePastZero() {
        let started = ModelDownloadQueueItem(
            id: "asr",
            name: "Qwen3 ASR",
            stage: .downloading,
            bytes: 2_000_000,
            expectedBytes: 8_000_000
        )
        XCTAssertEqual(started.sizeText?.contains(" of "), true)

        let waiting = ModelDownloadQueueItem(
            id: "asr",
            name: "Qwen3 ASR",
            stage: .waiting,
            expectedBytes: 8_000_000
        )
        XCTAssertEqual(waiting.sizeText?.contains(" of "), false)
        XCTAssertNil(
            ModelDownloadQueueItem(id: "x", name: "x", stage: .waiting).sizeText
        )
    }
}
