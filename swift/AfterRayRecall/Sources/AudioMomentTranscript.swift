import Foundation

public enum AudioTranscriptTiming: Equatable, Sendable {
    case aligned
    case coarse
    /// Compatibility-only fallback for older vaults while backfill is pending.
    /// Estimated cues are displayed, but never presented as actively spoken.
    case estimated
}

/// One bounded subtitle cue inside an audio segment.
public struct AudioTranscriptCue: Equatable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    /// Seconds from the start of the audio segment.
    public let start: TimeInterval
    public let duration: TimeInterval
    public let timing: AudioTranscriptTiming

    public var end: TimeInterval { start + duration }

    public init(
        id: Int,
        text: String,
        start: TimeInterval,
        duration: TimeInterval,
        timing: AudioTranscriptTiming = .estimated
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.duration = max(duration, 0)
        self.timing = timing
    }
}

/// Sentence split and playhead mapping for the audio chrome caption.
public enum AudioMomentTranscript {
    /// Break ASR text into sentences. Terminators stay on the preceding
    /// sentence. Decimal points (`3.14`) are not breaks; runs of `...` / `…`
    /// count as one ending.
    public static func splitSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let chars = Array(trimmed)
        var sentences: [String] = []
        var current: [Character] = []
        var index = 0
        while index < chars.count {
            let character = chars[index]
            current.append(character)
            let previous = index > 0 ? chars[index - 1] : nil
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if isTerminator(character, previous: previous, next: next) {
                while index + 1 < chars.count,
                      isTerminator(
                          chars[index + 1],
                          previous: chars[index],
                          next: index + 2 < chars.count ? chars[index + 2] : nil
                      )
                {
                    index += 1
                    current.append(chars[index])
                }
                let sentence = String(current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current.removeAll(keepingCapacity: true)
            }
            index += 1
        }
        let tail = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences
    }

    /// Map the full transcript onto `[0, segmentDuration]`, then keep sentences
    /// that still have speech at or after `momentOffset`.
    public static func cues(
        transcript: String?,
        segmentDuration: TimeInterval,
        momentOffset: TimeInterval
    ) -> [AudioTranscriptCue] {
        let sentences = splitSentences(transcript ?? "")
        guard !sentences.isEmpty else { return [] }
        let duration = max(segmentDuration, 0)
        guard duration > 0 else { return [] }

        let weights = sentences.map { sentenceWeight($0) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var cursor: TimeInterval = 0
        var mapped: [AudioTranscriptCue] = []
        mapped.reserveCapacity(sentences.count)
        for (index, sentence) in sentences.enumerated() {
            let share = TimeInterval(weights[index]) / TimeInterval(total)
            let length = index == sentences.count - 1
                ? max(duration - cursor, 0)
                : duration * share
            mapped.append(
                AudioTranscriptCue(
                    id: index,
                    text: sentence,
                    start: cursor,
                    duration: length
                )
            )
            cursor += length
        }

        let offset = max(momentOffset, 0)
        return mapped.filter { $0.end > offset + 0.000_1 }
    }

    /// Protocol 18 normally supplies segment bounds without decoding audio.
    /// The zero-duration fallback is only for incomplete fixtures/legacy data;
    /// it still caps presentation to three sentences instead of handing one
    /// unbounded transcript blob to SwiftUI.
    public static func displayCues(
        transcript: String?,
        alignedCues: [RecallTranscriptCue] = [],
        segmentDuration: TimeInterval,
        momentOffset: TimeInterval
    ) -> [AudioTranscriptCue] {
        if !alignedCues.isEmpty {
            let offset = max(momentOffset, 0)
            return alignedCues.compactMap { cue in
                let start = TimeInterval(cue.startOffsetMs) / 1_000
                let end = TimeInterval(cue.endOffsetMs) / 1_000
                guard end > start, end > offset + 0.000_1 else { return nil }
                return AudioTranscriptCue(
                    id: Int(cue.ordinal),
                    text: cue.text,
                    start: start,
                    duration: end - start,
                    timing: cue.timingKind == .aligned ? .aligned : .coarse
                )
            }
        }
        if segmentDuration > 0 {
            return cues(
                transcript: transcript,
                segmentDuration: segmentDuration,
                momentOffset: momentOffset
            )
        }
        return splitSentences(transcript ?? "")
            .prefix(3)
            .enumerated()
            .map { index, sentence in
                AudioTranscriptCue(
                    id: index,
                    text: sentence,
                    start: max(momentOffset, 0),
                    duration: 0
                )
            }
    }

    /// `playbackTime` is seconds from the start of the audio segment (the same
    /// clock `AVAudioPlayer.currentTime` uses after the moment seek).
    public static func positionIndex(
        in cues: [AudioTranscriptCue],
        at playbackTime: TimeInterval
    ) -> Int? {
        guard !cues.isEmpty, playbackTime.isFinite else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].start <= playbackTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    /// Highlighting is stricter than positioning: a paused playhead and a gap
    /// between aligned cues still keep the nearby three-line window in place,
    /// but neither claims that a sentence is currently being spoken.
    public static func activeIndex(
        in cues: [AudioTranscriptCue],
        at playbackTime: TimeInterval,
        isPlaying: Bool
    ) -> Int? {
        guard isPlaying,
              let candidate = positionIndex(in: cues, at: playbackTime)
        else { return nil }
        let cue = cues[candidate]
        guard cue.timing != .estimated,
              playbackTime >= cue.start,
              playbackTime < cue.end
        else { return nil }
        return candidate
    }

    /// Keeps the media-clock position inside a small stable caption window,
    /// independently of whether that cue is eligible for highlighting.
    public static func visibleCueRange(
        count: Int,
        positionIndex: Int?,
        windowSize: Int = 3
    ) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let size = min(max(windowSize, 1), count)
        let anchor = min(max(positionIndex ?? 0, 0), count - 1)
        let start = min(max(anchor - size / 2, 0), count - size)
        return start..<(start + size)
    }

    /// Deterministic decorative bars for the waveform control. Not PCM.
    public static func samples(seed: UInt64, count: Int = 32) -> [Float] {
        let barCount = max(count, 1)
        var state = seed == 0 ? 1 : seed
        return (0..<barCount).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let t = Double(index) / Double(max(barCount - 1, 1))
            let envelope = sin(t * .pi) * (0.55 + 0.45 * sin(t * .pi * 2.35))
            let noise = Double(state % 1_000) / 1_000
            let value = envelope * (0.62 + 0.38 * noise)
            return Float(min(1, max(0.14, value)))
        }
    }

    /// Stable per-artifact seed for decorative, non-PCM waveform bars.
    public static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { seed, byte in
            (seed ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func sentenceWeight(_ sentence: String) -> Int {
        max(sentence.count, 1)
    }

    private static func isTerminator(
        _ character: Character,
        previous: Character?,
        next: Character?
    ) -> Bool {
        switch character {
        case "。", "！", "？", "…":
            return true
        case ".":
            if let previous, previous.isNumber, let next, next.isNumber {
                return false
            }
            return true
        case "!", "?":
            return true
        default:
            return false
        }
    }
}
