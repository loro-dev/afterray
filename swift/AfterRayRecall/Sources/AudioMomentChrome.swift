import SwiftUI

/// Isolated presentation model for the playhead audio chrome. Snapshots drive
/// it directly; `RecallView` maps a selected historical moment onto it.
public struct AudioMomentChromeModel: Equatable, Sendable {
    public var hasAudio: Bool
    public var isPlaying: Bool
    public var isBuffering: Bool
    public var samples: [Float]
    public var cues: [AudioTranscriptCue]
    public var playbackTime: TimeInterval
    public var momentOffset: TimeInterval
    public var segmentDuration: TimeInterval
    public var timestamp: Date
    public var isLive: Bool

    public init(
        hasAudio: Bool,
        isPlaying: Bool = false,
        isBuffering: Bool = false,
        samples: [Float] = AudioMomentTranscript.samples(seed: 1),
        cues: [AudioTranscriptCue] = [],
        playbackTime: TimeInterval = 0,
        momentOffset: TimeInterval = 0,
        segmentDuration: TimeInterval = 60,
        timestamp: Date = Date(timeIntervalSince1970: 1_777_046_400),
        isLive: Bool = false
    ) {
        self.hasAudio = hasAudio
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.samples = samples
        self.cues = cues
        self.playbackTime = playbackTime
        self.momentOffset = momentOffset
        self.segmentDuration = segmentDuration
        self.timestamp = timestamp
        self.isLive = isLive
    }

    public var showsCaption: Bool { !cues.isEmpty }

    public var positionCueIndex: Int? {
        AudioMomentTranscript.positionIndex(in: cues, at: playbackTime)
    }

    public var activeCueIndex: Int? {
        AudioMomentTranscript.activeIndex(
            in: cues,
            at: playbackTime,
            isPlaying: isPlaying && !isBuffering
        )
    }

    /// 0...1 through the remaining audio after the playhead moment.
    public var remainingProgress: Double? {
        guard isPlaying || isBuffering else { return nil }
        let span = segmentDuration - momentOffset
        guard span > 0 else { return nil }
        return min(1, max(0, (playbackTime - momentOffset) / span))
    }
}

/// Waveform play control plus from-this-moment ASR caption, meant to sit
/// directly above `PlayheadTimestamp`.
public struct AudioMomentChrome: View {
    /// The control is the layout anchor. Captions deliberately overflow above
    /// this fixed-height box so their presence and line count cannot move it.
    static let controlHeight: CGFloat = 50
    static let captionGap: CGFloat = 12
    /// Keeps the enlarged control's bottom edge at the established position.
    static let recallOffsetY: CGFloat = -68

    @Environment(\.afterRayCopy) private var copy
    public var model: AudioMomentChromeModel
    public var onToggle: () -> Void
    public var playbackTime: (() -> TimeInterval)?

    public init(
        model: AudioMomentChromeModel,
        onToggle: @escaping () -> Void,
        playbackTime: (() -> TimeInterval)? = nil
    ) {
        self.model = model
        self.onToggle = onToggle
        self.playbackTime = playbackTime
    }

    public var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 12.0,
                paused: !model.isPlaying || playbackTime == nil
            )
        ) { _ in
            let presented = presentedModel
            if presented.hasAudio {
                ZStack(alignment: .bottom) {
                    if presented.showsCaption {
                        AudioMomentCaption(
                            cues: presented.cues,
                            positionIndex: presented.positionCueIndex,
                            activeIndex: presented.activeCueIndex
                        )
                        .offset(y: -(Self.controlHeight + Self.captionGap))
                    }
                    AudioWaveformButton(
                        samples: presented.samples,
                        progress: presented.remainingProgress,
                        isPlaying: presented.isPlaying,
                        isBuffering: presented.isBuffering,
                        help: playHelp,
                        action: onToggle
                    )
                }
                .frame(maxWidth: 700)
                .frame(height: Self.controlHeight, alignment: .bottom)
                .accessibilityElement(children: .contain)
            }
        }
        // `TimelineView` otherwise accepts the overlay's full proposed height.
        // Its vertical size must remain the capsule's fixed anchor box rather
        // than the entire recall surface.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var presentedModel: AudioMomentChromeModel {
        guard model.isPlaying, let playbackTime else { return model }
        var current = model
        current.playbackTime = playbackTime()
        return current
    }

    private var playHelp: String {
        if model.isBuffering { return copy.recall.cancelAudio }
        if model.isPlaying { return copy.recall.pauseAudio }
        return copy.recall.playAudio
    }
}

/// Dim stage used by the snapshot tool so the chrome can be reviewed without
/// `RecallView`, a daemon, or real audio.
public struct AudioMomentChromeStage: View {
    public var model: AudioMomentChromeModel
    public var onToggle: () -> Void

    public init(
        model: AudioMomentChromeModel,
        onToggle: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onToggle = onToggle
    }

    public var body: some View {
        ZStack {
            RecallPalette.background
            AudioMomentStageTrack()
                .padding(.horizontal, 56)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            PlayheadTimestamp(date: model.timestamp, isLive: model.isLive)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // The caption is overlay chrome: it must never move the timestamp
            // or the timeline strip when its transcript wraps.
            AudioMomentChrome(model: model, onToggle: onToggle)
                .padding(.bottom, 290)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .afterRayLocalized()
    }
}

struct AudioWaveformButton: View {
    let samples: [Float]
    let progress: Double?
    let isPlaying: Bool
    let isBuffering: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                transportGlyph
                    .frame(width: 18, height: 18)
                    // Play triangles sit optically left of geometric center.
                    .padding(.leading, isPlaying || isBuffering ? 0 : 1)
                AudioWaveformBars(
                    samples: samples,
                    progress: progress,
                    isPlaying: isPlaying,
                    isBuffering: isBuffering
                )
                .frame(width: 220, height: 28)
            }
            .padding(.leading, 15)
            .padding(.trailing, 17)
            .padding(.vertical, 11)
            .background(Color.black.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.44), radius: 16, y: 6)
        }
        .buttonStyle(AudioWaveformPressStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var transportGlyph: some View {
        if isBuffering {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RecallPalette.textPrimary)
        }
    }
}

struct AudioWaveformBars: View {
    let samples: [Float]
    let progress: Double?
    let isPlaying: Bool
    let isBuffering: Bool

    var body: some View {
        Canvas { context, size in
            let count = max(samples.count, 1)
            let gap: CGFloat = 2
            let barWidth = max(
                1.6,
                (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            )
            let playhead = progress.map { max(0, min(1, $0)) }
            for index in 0..<count {
                let amplitude = CGFloat(samples[min(index, samples.count - 1)])
                let height = max(3, size.height * amplitude)
                let x = CGFloat(index) * (barWidth + gap)
                let y = (size.height - height) / 2
                let fraction = (CGFloat(index) + 0.5) / CGFloat(count)
                let played = playhead.map { fraction <= $0 } ?? false
                let color: Color
                if isBuffering {
                    color = Color.white.opacity(0.58)
                } else if played {
                    color = RecallPalette.ray
                } else if isPlaying {
                    color = Color.white.opacity(0.50)
                } else {
                    color = Color.white.opacity(0.66)
                }
                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color)
                )
            }
        }
        .accessibilityHidden(true)
        .opacity(isBuffering ? 0.85 : 1)
    }
}

struct AudioMomentCaption: View {
    let cues: [AudioTranscriptCue]
    let positionIndex: Int?
    let activeIndex: Int?
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    var body: some View {
        Text(caption)
            .lineLimit(3)
            .lineSpacing(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 600)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
            .accessibilityLabel(plainCaption)
    }

    private var plainCaption: String {
        var text = ""
        for index in visibleCueRange {
            if index > visibleCueRange.lowerBound {
                text.append(Self.separator(before: cues[index - 1].text, after: cues[index].text))
            }
            text.append(cues[index].text)
        }
        return text
    }

    private var caption: AttributedString {
        var result = AttributedString()
        for index in visibleCueRange {
            let cue = cues[index]
            if index > visibleCueRange.lowerBound {
                var gap = AttributedString(
                    Self.separator(before: cues[index - 1].text, after: cue.text)
                )
                gap.font = .system(size: fontSize, weight: .medium, design: .rounded)
                gap.foregroundColor = RecallPalette.textSecondary
                result.append(gap)
            }
            var piece = AttributedString(cue.text)
            let isActive = index == activeIndex
            piece.font = .system(
                size: fontSize,
                weight: isActive ? .semibold : .medium,
                design: .rounded
            )
            piece.foregroundColor = isActive
                ? RecallPalette.textPrimary
                : RecallPalette.textSecondary
            if isActive {
                piece.backgroundColor = RecallPalette.ray.opacity(0.32)
            }
            result.append(piece)
        }
        return result
    }

    private var visibleCueRange: Range<Int> {
        AudioMomentTranscript.visibleCueRange(
            count: cues.count,
            positionIndex: positionIndex
        )
    }

    private static func separator(before: String, after: String) -> String {
        guard let next = after.first else { return "" }
        if next.isWhitespace { return "" }
        if next.isASCII { return " " }
        if let previous = before.last, previous.isASCII, previous != "." {
            return " "
        }
        return ""
    }
}

struct AudioMomentStageTrack: View {
    var body: some View {
        HStack(spacing: 3) {
            Capsule().fill(Color(red: 0.38, green: 0.34, blue: 0.72))
            Capsule().fill(Color(red: 0.93, green: 0.20, blue: 0.14).opacity(0.85))
            Capsule().fill(Color(red: 0.19, green: 0.46, blue: 0.58))
            Capsule().fill(Color.white.opacity(0.10))
        }
        .frame(height: 10)
        .overlay(alignment: .center) {
            Rectangle()
                .fill(RecallPalette.ray)
                .frame(width: 2, height: 18)
                .shadow(color: RecallPalette.ray.opacity(0.8), radius: 5)
        }
        .accessibilityHidden(true)
    }
}

private struct AudioWaveformPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
