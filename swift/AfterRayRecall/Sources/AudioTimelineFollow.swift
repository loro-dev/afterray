import Foundation

/// Why the timeline is moving. User travel owns the transport boundary;
/// playback travel is a derived presentation of the current audio clock.
public enum RecallTimelineTravelOrigin: Equatable, Sendable {
    case user
    case audioPlayback
}

public enum RecallTimelineTravelPolicy {
    /// A human gesture changes intent and must discard the old media source.
    /// Automatic playback travel must keep that source alive.
    public static func invalidatesAudio(_ origin: RecallTimelineTravelOrigin) -> Bool {
        origin == .user
    }
}

/// Immutable source metadata plus the current media clock, sampled without
/// publishing that clock through the Recall root.
public struct AudioTimelinePlaybackPosition: Equatable, Sendable {
    public let sourceMomentID: String
    public let sourceSessionID: String
    public let sourceCapturedAtMs: Int64
    public let timelineMs: Int64

    public init(
        sourceMomentID: String,
        sourceSessionID: String,
        sourceCapturedAtMs: Int64,
        timelineMs: Int64
    ) {
        self.sourceMomentID = sourceMomentID
        self.sourceSessionID = sourceSessionID
        self.sourceCapturedAtMs = sourceCapturedAtMs
        self.timelineMs = timelineMs
    }
}

/// The capture frame represented by one sampled audio position.
public struct AudioTimelineFollowTarget: Equatable, Sendable {
    public let moment: RecallMoment
    public let nextBoundaryMs: Int64?

    public init(moment: RecallMoment, nextBoundaryMs: Int64?) {
        self.moment = moment
        self.nextBoundaryMs = nextBoundaryMs
    }
}

/// O(log n) media-clock to capture-frame mapping.
public enum AudioTimelineFollow {
    public static let maximumCheckInterval: TimeInterval = 0.25
    public static let minimumCheckInterval: TimeInterval = 1.0 / 60.0

    // @dec:audio-playback-follows-timeline — docs/decisions/active/product/2026-08-24-audio-playback-follows-timeline.md
    public static func target(
        for position: AudioTimelinePlaybackPosition,
        moments: [RecallMoment]
    ) -> AudioTimelineFollowTarget? {
        guard position.timelineMs >= position.sourceCapturedAtMs,
              let index = RecallPlayhead.resolveIndex(
                  playheadMs: position.timelineMs,
                  moments: moments
              )
        else { return nil }

        let moment = moments[index]
        guard moment.sessionId == position.sourceSessionID else { return nil }

        var nextBoundaryMs: Int64?
        if index + 1 < moments.count {
            let next = moments[index + 1]
            if next.sessionId == position.sourceSessionID {
                let gap = next.capturedAtMs - moment.capturedAtMs
                if gap > TimelineLayout.idleGapThresholdMs,
                   position.timelineMs > moment.capturedAtMs + TimelineLayout.captureIntervalMs
                {
                    return nil
                }
                nextBoundaryMs = next.capturedAtMs
            }
        }
        return AudioTimelineFollowTarget(
            moment: moment,
            nextBoundaryMs: nextBoundaryMs
        )
    }

    /// Sleep near the next capture boundary, with a short cap so cancellation,
    /// decoder drift, and a timeline-window replacement are observed promptly.
    public static func nextCheckInterval(
        position: AudioTimelinePlaybackPosition,
        target: AudioTimelineFollowTarget?
    ) -> TimeInterval {
        guard let nextMs = target?.nextBoundaryMs else {
            return maximumCheckInterval
        }
        let seconds = Double(nextMs - position.timelineMs) / 1_000
        return min(max(seconds, minimumCheckInterval), maximumCheckInterval)
    }
}

/// Playback-owned presentation data. `sourceMomentID` never changes during a
/// session; `followedMomentID` advances with capture frames.
public struct RecallAudioPlaybackContext: Equatable, Sendable {
    public let sourceMomentID: String
    public let followedMomentID: String
    public let segmentID: String
    public let artifactID: String
    public let sourceOffset: TimeInterval
    public let segmentStartedAtMs: Int64
    public let segmentEndedAtMs: Int64
    public let transcriptText: String?
    public let transcriptCues: [RecallTranscriptCue]

    public var segmentDuration: TimeInterval {
        TimeInterval(max(segmentEndedAtMs - segmentStartedAtMs, 0)) / 1_000
    }

    public init(
        sourceMomentID: String,
        followedMomentID: String,
        segmentID: String,
        artifactID: String,
        sourceOffset: TimeInterval,
        segmentStartedAtMs: Int64,
        segmentEndedAtMs: Int64,
        transcriptText: String?,
        transcriptCues: [RecallTranscriptCue] = []
    ) {
        self.sourceMomentID = sourceMomentID
        self.followedMomentID = followedMomentID
        self.segmentID = segmentID
        self.artifactID = artifactID
        self.sourceOffset = sourceOffset
        self.segmentStartedAtMs = segmentStartedAtMs
        self.segmentEndedAtMs = segmentEndedAtMs
        self.transcriptText = transcriptText
        self.transcriptCues = transcriptCues
    }
}
