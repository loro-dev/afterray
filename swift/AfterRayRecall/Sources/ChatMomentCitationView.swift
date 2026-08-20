import CoreGraphics
import SwiftUI

/// A screenshot citation backed by afterrayd's read-only moment APIs.
///
/// First paint uses the filmstrip thumbnail; the card then upgrades to a
/// chat-preview still (hot JPEG or exact GOP frame). The whole card remains a
/// moment link when the capture was deleted or could not be decoded, so
/// missing media never erases the citation itself.
struct ChatMomentCitationView: View {
    @Environment(\.afterRayCopy) private var copy
    let label: String
    let momentID: String
    let thumbnailLoader: RecallThumbnailLoader?
    let previewLoader: RecallChatPreviewLoader?
    let momentLoader: RecallMomentLoader?
    let onOpenMoment: ((String) -> Void)?

    @State private var image: CGImage?
    @State private var capturedAtMs: Int64?
    @State private var loadFinished = false

    init(
        label: String,
        momentID: String,
        thumbnailLoader: RecallThumbnailLoader?,
        previewLoader: RecallChatPreviewLoader? = nil,
        momentLoader: RecallMomentLoader? = nil,
        onOpenMoment: ((String) -> Void)?
    ) {
        self.label = label
        self.momentID = momentID
        self.thumbnailLoader = thumbnailLoader
        self.previewLoader = previewLoader
        self.momentLoader = momentLoader
        self.onOpenMoment = onOpenMoment
    }

    var body: some View {
        Button(action: openMoment) {
            ZStack(alignment: .bottomLeading) {
                preview
                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .bottom, spacing: 8) {
                        Text(title)
                            .font(.callout)
                            .bold()
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                    if let timeLabel {
                        Text(timeLabel)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .opacity(0.92)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 440)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(onOpenMoment == nil)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .task(id: momentID, loadMedia)
    }

    private var title: String {
        label.isEmpty ? copy.chat.capturedMoment : label
    }

    private var timeLabel: String? {
        capturedAtMs.map { ChatMomentTimeLabel.format(capturedAtMs: $0) }
    }

    private var helpText: String {
        if let timeLabel {
            return copy.chat.openCapturedMomentAt(timeLabel)
        }
        return copy.chat.openCapturedMoment
    }

    private var accessibilityText: String {
        if let timeLabel {
            return copy.chat.openCapturedTitledAt(title, timeLabel)
        }
        return copy.chat.openCapturedTitled(title)
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if loadFinished {
            Label(copy.chat.screenshotUnavailable, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(RecallPalette.ray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openMoment() {
        onOpenMoment?(momentID)
    }

    @MainActor
    private func loadMedia() async {
        image = nil
        capturedAtMs = nil
        loadFinished = false
        defer { loadFinished = true }

        async let meta = loadMoment()
        async let thumb = loadThumbnail()
        async let preview = loadPreview()

        if let moment = await meta {
            capturedAtMs = moment.capturedAtMs
        }
        if Task.isCancelled { return }

        if RecallChatPreviewCache.shared.cached(momentID: momentID) == nil,
           let thumb = await thumb {
            image = thumb
        }
        if Task.isCancelled { return }
        if let preview = await preview {
            image = preview
        } else if image == nil, let thumb = await thumb {
            image = thumb
        }
    }

    private func loadMoment() async -> RecallMoment? {
        guard let momentLoader else { return nil }
        return try? await momentLoader(momentID)
    }

    private func loadThumbnail() async -> CGImage? {
        guard let thumbnailLoader else { return nil }
        return await RecallThumbnailCache.shared.image(
            momentID: momentID,
            loader: thumbnailLoader
        )
    }

    private func loadPreview() async -> CGImage? {
        guard let previewLoader else { return nil }
        return await RecallChatPreviewCache.shared.image(
            momentID: momentID,
            loader: previewLoader
        )
    }
}

/// Full local calendar date + time with a timezone suffix.
///
/// Uses the supplied `TimeZone` (default: the user's current zone) so tests
/// can pin PDT / GMT+8 without depending on the machine locale.
enum ChatMomentTimeLabel {
    static func format(
        capturedAtMs: Int64,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1_000)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date)) \(suffix(for: timeZone, at: date))"
    }

    /// Named abbreviations (`PDT`) come from a pinned English formatter —
    /// `TimeZone.abbreviation` often returns `GMT-7` and is locale-flaky.
    static func suffix(for timeZone: TimeZone, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "zzz"
        let abbreviation = formatter.string(from: date)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !abbreviation.isEmpty {
            return abbreviation
        }
        return gmtOffset(for: timeZone, at: date)
    }

    static func gmtOffset(for timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        }
        return String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }
}
