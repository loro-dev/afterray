import Foundation

/// Streaming-safe slices of assistant Markdown.
///
/// Closed prose, lists, tables, and quotes are coalesced into one
/// `.markdown` value so MarkdownUI owns structure. The splitter only
/// isolates the things a full re-parse would get wrong mid-stream:
/// unclosed fences, standalone moment citations, and unfinished image
/// syntax. Block identity is prefix-stable: completed leading slices
/// do not change as later tokens arrive.
public enum MarkdownBlock: Equatable, Sendable {
    case markdown(String)
    case momentImage(label: String, momentID: String)
    case code(language: String?, text: String, closed: Bool)
}

public enum StreamingMarkdown {
    public static func blocks(from source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [MarkdownBlock] = []
        var markdownLines: [String] = []
        var index = 0

        func flushMarkdown(closeDangling: Bool) {
            var text = trimBlankEdges(markdownLines.joined(separator: "\n"))
            markdownLines.removeAll(keepingCapacity: true)
            guard !isBlank(text) else { return }
            text = rewriteMomentLinks(text)
            text = escapeUntrustedImages(text)
            if closeDangling {
                text = closeDanglingInlineMarkup(text)
            }
            text = trimBlankEdges(text)
            guard !isBlank(text) else { return }
            blocks.append(.markdown(text))
        }

        while index < rawLines.count {
            let line = rawLines[index]

            if let fence = fenceMatch(line) {
                flushMarkdown(closeDangling: false)
                var body: [String] = []
                index += 1
                var closed = false
                while index < rawLines.count {
                    if fenceMatch(rawLines[index]) != nil {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(rawLines[index])
                    index += 1
                }
                blocks.append(.code(language: fence, text: body.joined(separator: "\n"), closed: closed))
                continue
            }

            if let image = momentImageMatch(line) {
                flushMarkdown(closeDangling: false)
                blocks.append(.momentImage(label: image.label, momentID: image.momentID))
                index += 1
                continue
            }

            if isIncompleteMomentImage(line) {
                flushMarkdown(closeDangling: false)
                markdownLines.append(line)
                index += 1
                while index < rawLines.count {
                    markdownLines.append(rawLines[index])
                    index += 1
                }
                // Leave the unfinished `![...](afterray://moment/` line raw so
                // closeDangling cannot strip the URL before `)` arrives.
                flushMarkdown(closeDangling: false)
                continue
            }

            markdownLines.append(line)
            index += 1
        }

        flushMarkdown(closeDangling: true)
        return blocks
    }

    public static func attributedInline(_ text: String) -> AttributedString {
        let rewritten = rewriteMomentLinks(text)
        let closed = closeDanglingInlineMarkup(rewritten)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: closed, options: options) {
            return parsed
        }
        return AttributedString(text)
    }

    public static func closeDanglingInlineMarkup(_ text: String) -> String {
        var result = stripIncompleteLink(text)
        if unpairedCount(of: "`", in: result) % 2 == 1 {
            result.append("`")
        }
        let boldCount = occurrences(of: "**", in: result)
        if boldCount % 2 == 1 {
            result.append("**")
        }
        if unpairedItalics(in: result) {
            result.append("*")
        }
        return result
    }

    public static func momentID(from url: URL) -> String? {
        guard url.scheme == "afterray", url.host == "moment" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return nil }
        guard id.unicodeScalars.allSatisfy({ momentIDCharacters.contains($0) }) else { return nil }
        return id
    }

    public static func rewriteMomentLinks(_ text: String) -> String {
        if text.contains("](afterray://moment/") { return text }
        guard let regex = try? NSRegularExpression(pattern: #"afterray://moment/([A-Za-z0-9\-]+)"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "[moment](afterray://moment/$1)"
        )
    }

    /// Turns leftover `![alt](url)` into literal text so MarkdownUI cannot
    /// treat an http/file/data (or embedded moment) image as media.
    public static func escapeUntrustedImages(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]\n]{0,160})\]\(([^)\n]*)\)"#) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: range)
        var result = text
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result) else { continue }
            let original = String(result[full])
            guard original.hasPrefix("!") else { continue }
            result.replaceSubrange(full, with: "\\!\\" + original.dropFirst())
        }
        return result
    }

    /// Agent-authored images are deliberately narrower than general Markdown.
    /// Only a standalone, protocol-backed moment reference becomes media; an
    /// http/file/data image stays ordinary selectable text and never triggers
    /// a resource read.
    private static func momentImageMatch(_ line: String) -> (label: String, momentID: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^!\[([^\]\n]{0,160})\]\(afterray://moment/([A-Za-z0-9-]+)\)\s*$"#
        ) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.range == range,
              let labelRange = Range(match.range(at: 1), in: line),
              let momentRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[labelRange]), String(line[momentRange]))
    }

    /// A standalone moment citation that has started but is still missing `)`.
    /// Flushed separately so the preceding closed Markdown keeps its identity.
    private static func isIncompleteMomentImage(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("![") else { return false }
        guard trimmed.contains("](afterray://moment/") else { return false }
        return momentImageMatch(line) == nil
    }

    private static func fenceMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return language.isEmpty ? "" : language
    }

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// Drop leading/trailing blank lines so a closed prefix keeps the same
    /// identity whether the next token is a fence, a citation, or more prose.
    private static func trimBlankEdges(_ text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static let momentIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))

    private static func unpairedCount(of mark: Character, in text: String) -> Int {
        text.filter { $0 == mark }.count
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    /// Italics that are not part of `**bold**`.
    private static func unpairedItalics(in text: String) -> Bool {
        var singles = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "*" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "*" {
                    index = text.index(after: next)
                    continue
                }
                singles += 1
            }
            index = text.index(after: index)
        }
        return singles % 2 == 1
    }

    private static func stripIncompleteLink(_ text: String) -> String {
        guard let open = text.lastIndex(of: "[") else { return text }
        let afterOpen = text[open...]
        if afterOpen.contains("](") {
            if linkDestinationIsClosed(afterOpen) {
                return text
            }
            return String(text[..<open]) + String(afterOpen.dropFirst().prefix { $0 != "]" })
        }
        if !afterOpen.contains("]") {
            return String(text[..<open]) + String(afterOpen.dropFirst())
        }
        return text
    }

    /// `[label](url)` is complete once a `)` closes the destination, even if
    /// more prose follows on the same line.
    private static func linkDestinationIsClosed(_ afterOpen: Substring) -> Bool {
        guard let closeBracket = afterOpen.firstIndex(of: "]") else { return false }
        let rest = afterOpen[closeBracket...]
        guard rest.hasPrefix("](") else { return false }
        return rest.contains(")")
    }
}
