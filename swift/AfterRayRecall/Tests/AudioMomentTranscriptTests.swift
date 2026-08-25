import XCTest
@testable import AfterRayRecall

final class AudioMomentTranscriptTests: XCTestCase {
    func testSplitKeepsCJKAndLatinTerminatorsOnTheSentence() {
        XCTAssertEqual(
            AudioMomentTranscript.splitSentences("Hello there. How are you? Fine!"),
            ["Hello there.", "How are you?", "Fine!"]
        )
        XCTAssertEqual(
            AudioMomentTranscript.splitSentences("你好。今天怎么样？还行！"),
            ["你好。", "今天怎么样？", "还行！"]
        )
    }

    func testSplitDoesNotBreakDecimals() {
        XCTAssertEqual(
            AudioMomentTranscript.splitSentences("It was 3.14 meters. Done."),
            ["It was 3.14 meters.", "Done."]
        )
    }

    func testSplitCollapsesEllipsisAndKeepsATailWithoutTerminator() {
        XCTAssertEqual(
            AudioMomentTranscript.splitSentences("Wait... then we left"),
            ["Wait...", "then we left"]
        )
        XCTAssertEqual(AudioMomentTranscript.splitSentences("   "), [])
        XCTAssertEqual(AudioMomentTranscript.splitSentences(""), [])
    }

    func testCuesDropSpeechBeforeTheMomentAndKeepAStraddle() {
        let transcript = "AAAA. BBBB. CCCC. DDDD."
        let cues = AudioMomentTranscript.cues(
            transcript: transcript,
            segmentDuration: 40,
            momentOffset: 15
        )
        XCTAssertEqual(cues.map(\.text), ["BBBB.", "CCCC.", "DDDD."])
        XCTAssertEqual(cues[0].start, 10, accuracy: 0.01)
        XCTAssertGreaterThan(cues[0].end, 15)
        XCTAssertEqual(cues.last?.end ?? 0, 40, accuracy: 0.01)
    }

    func testCuesIgnoreBlankTranscriptAndZeroDuration() {
        XCTAssertTrue(
            AudioMomentTranscript.cues(
                transcript: "   ",
                segmentDuration: 10,
                momentOffset: 0
            ).isEmpty
        )
        XCTAssertTrue(
            AudioMomentTranscript.cues(
                transcript: "Hello.",
                segmentDuration: 0,
                momentOffset: 0
            ).isEmpty
        )
        XCTAssertTrue(
            AudioMomentTranscript.cues(
                transcript: "Hello. World.",
                segmentDuration: 20,
                momentOffset: 20
            ).isEmpty
        )
    }

    func testDisplayCuesBoundIncompleteMetadataInsteadOfRenderingOneLongBlob() {
        let cues = AudioMomentTranscript.displayCues(
            transcript: "First. Second. Third. Fourth. Fifth.",
            segmentDuration: 0,
            momentOffset: 12
        )

        XCTAssertEqual(cues.map(\.text), ["First.", "Second.", "Third."])
        XCTAssertEqual(cues.first?.start, 12)
        XCTAssertEqual(cues.first?.duration, 0)
    }

    func testEstimatedCuesNeverClaimAnActiveSentence() {
        let cues = AudioMomentTranscript.cues(
            transcript: "One. Two. Three.",
            segmentDuration: 30,
            momentOffset: 0
        )
        XCTAssertEqual(cues.count, 3)
        XCTAssertNil(
            AudioMomentTranscript.activeIndex(in: cues, at: 12, isPlaying: false)
        )
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 0, isPlaying: true))
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 12, isPlaying: true))
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 29.5, isPlaying: true))
    }

    func testAlignedCuesUseExactRangesAndLeaveSilenceUnhighlighted() {
        let cues = AudioMomentTranscript.displayCues(
            transcript: "ignored fallback",
            alignedCues: [
                RecallTranscriptCue(
                    ordinal: 0,
                    text: "One.",
                    startOffsetMs: 1_000,
                    endOffsetMs: 2_000,
                    timingKind: .aligned
                ),
                RecallTranscriptCue(
                    ordinal: 1,
                    text: "Two.",
                    startOffsetMs: 3_000,
                    endOffsetMs: 4_000,
                    timingKind: .aligned
                ),
            ],
            segmentDuration: 10,
            momentOffset: 0
        )

        XCTAssertEqual(cues.map(\.text), ["One.", "Two."])
        XCTAssertEqual(
            AudioMomentTranscript.activeIndex(in: cues, at: 1.5, isPlaying: true),
            0
        )
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 2.5, isPlaying: true))
        XCTAssertEqual(
            AudioMomentTranscript.activeIndex(in: cues, at: 3.5, isPlaying: true),
            1
        )
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 9, isPlaying: true))
    }

    func testPositionRemainsClockBasedWhilePausedOrBetweenCues() {
        let cues = [
            AudioTranscriptCue(id: 0, text: "One.", start: 1, duration: 1, timing: .aligned),
            AudioTranscriptCue(id: 1, text: "Two.", start: 3, duration: 1, timing: .aligned),
            AudioTranscriptCue(id: 2, text: "Three.", start: 5, duration: 1, timing: .aligned),
            AudioTranscriptCue(id: 3, text: "Four.", start: 7, duration: 1, timing: .aligned),
        ]

        XCTAssertEqual(AudioMomentTranscript.positionIndex(in: cues, at: 7.5), 3)
        XCTAssertEqual(AudioMomentTranscript.positionIndex(in: cues, at: 6.5), 2)
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 7.5, isPlaying: false))
        XCTAssertNil(AudioMomentTranscript.activeIndex(in: cues, at: 6.5, isPlaying: true))
        XCTAssertEqual(
            AudioMomentTranscript.visibleCueRange(count: 4, positionIndex: 3),
            1..<4
        )
    }

    func testVisibleCueWindowKeepsTheClockPositionOnScreen() {
        XCTAssertEqual(
            AudioMomentTranscript.visibleCueRange(count: 6, positionIndex: nil),
            0..<3
        )
        XCTAssertEqual(
            AudioMomentTranscript.visibleCueRange(count: 6, positionIndex: 3),
            2..<5
        )
        XCTAssertEqual(
            AudioMomentTranscript.visibleCueRange(count: 6, positionIndex: 5),
            3..<6
        )
    }

    func testChromeModelProgressAndActiveIndex() {
        let cues = AudioMomentTranscript.displayCues(
            transcript: nil,
            alignedCues: [
                RecallTranscriptCue(
                    ordinal: 0,
                    text: "Two.",
                    startOffsetMs: 10_000,
                    endOffsetMs: 25_000,
                    timingKind: .aligned
                )
            ],
            segmentDuration: 30,
            momentOffset: 10
        )
        var model = AudioMomentChromeModel(
            hasAudio: true,
            isPlaying: true,
            cues: cues,
            playbackTime: 20,
            momentOffset: 10,
            segmentDuration: 30
        )
        XCTAssertEqual(model.remainingProgress ?? -1, 0.5, accuracy: 0.01)
        XCTAssertNotNil(model.activeCueIndex)
        model.isPlaying = false
        XCTAssertNil(model.remainingProgress)
        XCTAssertNil(model.activeCueIndex)
        XCTAssertEqual(model.positionCueIndex, 0)
        XCTAssertTrue(model.showsCaption, "pausing must not unmount transcript text")
        XCTAssertFalse(AudioMomentChromeModel(hasAudio: false).showsCaption)
    }

    func testSamplesStayInRangeAndAreDeterministic() {
        let a = AudioMomentTranscript.samples(seed: 42, count: 32)
        let b = AudioMomentTranscript.samples(seed: 42, count: 32)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { $0 >= 0.14 && $0 <= 1 })
        XCTAssertNotEqual(
            AudioMomentTranscript.samples(seed: 1, count: 8),
            AudioMomentTranscript.samples(seed: 2, count: 8)
        )
        XCTAssertEqual(
            AudioMomentTranscript.stableSeed("audio-1"),
            AudioMomentTranscript.stableSeed("audio-1")
        )
        XCTAssertNotEqual(
            AudioMomentTranscript.stableSeed("audio-1"),
            AudioMomentTranscript.stableSeed("audio-2")
        )
    }
}
