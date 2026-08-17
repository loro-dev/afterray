import MarkdownUI
import SwiftUI

/// Renders streaming-safe Markdown slices with MarkdownUI.
///
/// Closed `.markdown` chunks go through the library (tables, nested lists,
/// GFM). Open fences keep a dedicated code chrome so a half-written fence
/// cannot reshuffle later blocks. Image providers refuse every URL except
/// a standalone `afterray://moment/ID` citation — the splitter already
/// extracts those, so the providers are a second lock.
struct ChatMarkdownView: View {
    let blocks: [MarkdownBlock]
    let thumbnailLoader: RecallThumbnailLoader?
    let onOpenMoment: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let source):
                    Markdown(source)
                        .markdownTheme(.afterRayChat)
                        .markdownImageProvider(
                            ChatSecureImageProvider(
                                thumbnailLoader: thumbnailLoader,
                                onOpenMoment: onOpenMoment
                            )
                        )
                        .markdownInlineImageProvider(ChatDeniedInlineImageProvider())
                        .environment(\.openURL, OpenURLAction(handler: handleOpenURL))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .momentImage(let label, let momentID):
                    ChatMomentCitationView(
                        label: label,
                        momentID: momentID,
                        thumbnailLoader: thumbnailLoader,
                        onOpenMoment: onOpenMoment
                    )
                case .code(let language, let text, let closed):
                    ChatCodeBlock(language: language, text: text, closed: closed)
                }
            }
        }
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        if let momentID = StreamingMarkdown.momentID(from: url) {
            onOpenMoment?(momentID)
            return .handled
        }
        return .systemAction
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let text: String
    let closed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text((language?.isEmpty == false ? language! : "code").uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(ChatPalette.coral.opacity(0.9))
                Spacer()
                if !closed {
                    Text("streaming")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ChatPalette.tertiary)
                }
            }
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(ChatPalette.codeFill)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ChatPalette.accent.opacity(0.75))
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Loads only `afterray://moment/ID`. Every other URL is rendered as
/// selectable text so MarkdownUI's default NetworkImage path never runs.
private struct ChatSecureImageProvider: ImageProvider {
    let thumbnailLoader: RecallThumbnailLoader?
    let onOpenMoment: ((String) -> Void)?

    func makeImage(url: URL?) -> some View {
        if let url, let momentID = StreamingMarkdown.momentID(from: url) {
            ChatMomentCitationView(
                label: url.lastPathComponent,
                momentID: momentID,
                thumbnailLoader: thumbnailLoader,
                onOpenMoment: onOpenMoment
            )
        } else {
            Text(url?.absoluteString ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChatPalette.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ChatDeniedInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        throw ChatDeniedImageError.inlineDisabled
    }
}

private enum ChatDeniedImageError: Error {
    case inlineDisabled
}

extension Theme {
    /// Dark chat palette: 13pt medium body, coral list markers, accent
    /// quote bar, code chrome that matches `ChatCodeBlock`.
    static let afterRayChat = Theme()
        .text {
            ForegroundColor(ChatPalette.label)
            FontSize(13)
            FontWeight(.medium)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(ChatPalette.coral.opacity(0.95))
            BackgroundColor(Color.white.opacity(0.06))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(ChatPalette.accent)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(20)
                    ForegroundColor(ChatPalette.label)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(ChatPalette.label)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                    ForegroundColor(ChatPalette.label)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .heading4 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13.5)
                    ForegroundColor(ChatPalette.label)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .heading5 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13.5)
                    ForegroundColor(ChatPalette.label)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .heading6 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13.5)
                    ForegroundColor(ChatPalette.secondary)
                }
                .markdownMargin(top: 2, bottom: 4)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(ChatPalette.accent.opacity(0.7))
                    .frame(width: 2)
                configuration.label
                    .markdownTextStyle {
                        FontStyle(.italic)
                        ForegroundColor(ChatPalette.secondary)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            ChatCodeBlock(
                language: configuration.language,
                text: configuration.content,
                closed: true
            )
            .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15))
        }
        .bulletedListMarker { _ in
            Circle()
                .fill(ChatPalette.coral.opacity(0.85))
                .frame(width: 4, height: 4)
                .relativeFrame(minWidth: .em(1.4), alignment: .trailing)
        }
        .numberedListMarker { configuration in
            Text("\(configuration.itemNumber).")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatPalette.coral)
                .monospacedDigit()
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: ChatPalette.cardStroke))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.white.opacity(0.03))
                )
                .markdownMargin(top: 0, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    ForegroundColor(ChatPalette.label)
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
        }
        .thematicBreak {
            Rectangle()
                .fill(ChatPalette.separator)
                .frame(height: 1)
                .padding(.vertical, 4)
                .markdownMargin(top: 4, bottom: 4)
        }
}
