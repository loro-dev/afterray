import Foundation
import AfterRayRecall

/// Isolated audio-chrome states for snapshots. No real AAC.
public enum AudioCaptionFixtures {
    public static let clock = Date(timeIntervalSince1970: 1_777_046_400)

    public static let bilingual = """
        Thank you very much. 他改革的成像也大多在他退休之后才愈发显现出来。\
        这种工程不必在我的宽广胸襟。Let us keep going from here.
        """

    public static let meeting = """
        We should ship the waveform above the clock. The caption only starts \
        from this moment. Highlight the sentence that is playing now.
        """

    public static let longSequence = """
        First we opened the timeline. Then playback began. The background moved. \
        The clock followed it. This sentence must stay visible. User scrolling stops everything.
        """

    public static func idleAudioOnly() -> AudioMomentChromeModel {
        AudioMomentChromeModel(
            hasAudio: true,
            samples: AudioMomentTranscript.samples(seed: 11),
            timestamp: clock
        )
    }

    public static func idleWithCaption() -> AudioMomentChromeModel {
        model(
            transcript: meeting,
            offset: 8,
            duration: 40,
            playbackTime: 8,
            playing: false
        )
    }

    public static func playingHighlight() -> AudioMomentChromeModel {
        model(
            transcript: meeting,
            offset: 8,
            duration: 40,
            playbackTime: 18,
            playing: true
        )
    }

    public static func buffering() -> AudioMomentChromeModel {
        var state = playingHighlight()
        state.isPlaying = false
        state.isBuffering = true
        state.playbackTime = 8
        return state
    }

    public static func longBilingual() -> AudioMomentChromeModel {
        model(
            transcript: bilingual,
            offset: 4,
            duration: 50,
            playbackTime: 22,
            playing: true,
            seed: 23
        )
    }

    public static func midProgress() -> AudioMomentChromeModel {
        model(
            transcript: meeting,
            offset: 8,
            duration: 40,
            playbackTime: 31,
            playing: true,
            seed: 19
        )
    }

    public static func slidingCaption() -> AudioMomentChromeModel {
        model(
            transcript: longSequence,
            offset: 0,
            duration: 60,
            playbackTime: 44,
            playing: true,
            seed: 31
        )
    }

    public static func hiddenNoAudio() -> AudioMomentChromeModel {
        AudioMomentChromeModel(
            hasAudio: false,
            timestamp: clock
        )
    }

    private static func model(
        transcript: String,
        offset: TimeInterval,
        duration: TimeInterval,
        playbackTime: TimeInterval,
        playing: Bool,
        seed: UInt64 = 11
    ) -> AudioMomentChromeModel {
        AudioMomentChromeModel(
            hasAudio: true,
            isPlaying: playing,
            samples: AudioMomentTranscript.samples(seed: seed),
            cues: AudioMomentTranscript.cues(
                transcript: transcript,
                segmentDuration: duration,
                momentOffset: offset
            ),
            playbackTime: playbackTime,
            momentOffset: offset,
            segmentDuration: duration,
            timestamp: clock
        )
    }
}
