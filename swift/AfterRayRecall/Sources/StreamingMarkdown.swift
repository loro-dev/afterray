import Foundation

/// Line-oriented markdown so a half-finished stream cannot collapse the
/// whole assistant bubble. Each block is complete enough to render; an
/// unclosed fence stays a code block instead of poisoning later paragraphs.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletedList([String])
    case numberedList([String])
    case code(language: String?, text: String, closed: Bool)
    case quote(String)
    case rule
}

public enum StreamingMarkdown {
    public static func blocks(from source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < rawLines.count {
            let line = rawLines[index]

            if let fence = fenceMatch(line) {
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

            if let heading = headingMatch(line) {
                var text = heading.text
                let level = heading.level
                index += 1
                while index < rawLines.count, !isStructural(rawLines[index]), !rawLines[index].isEmpty {
                    text += "\n" + rawLines[index]
                    index += 1
                }
                blocks.append(.heading(level: level, text: text))
                continue
            }

            if isRule(line) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let item = bulletMatch(line) {
                var items = [item]
                index += 1
                while index < rawLines.count, let next = bulletMatch(rawLines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bulletedList(items))
                continue
            }

            if let item = numberedMatch(line) {
                var items = [item]
                index += 1
                while index < rawLines.count, let next = numberedMatch(rawLines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            if let quoted = quoteMatch(line) {
                var lines = [quoted]
                index += 1
                while index < rawLines.count, let next = quoteMatch(rawLines[index]) {
                    lines.append(next)
                    index += 1
                }
                blocks.append(.quote(lines.joined(separator: "\n")))
                continue
            }

            if line.isEmpty {
                index += 1
                continue
            }

            var paragraph = line
            index += 1
            while index < rawLines.count, !rawLines[index].isEmpty, !isStructural(rawLines[index]) {
                paragraph += "\n" + rawLines[index]
                index += 1
            }
            blocks.append(.paragraph(paragraph))
        }

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

    private static func isStructural(_ line: String) -> Bool {
        fenceMatch(line) != nil
            || headingMatch(line) != nil
            || isRule(line)
            || bulletMatch(line) != nil
            || numberedMatch(line) != nil
            || quoteMatch(line) != nil
    }

    private static func fenceMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return language.isEmpty ? "" : language
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marks: [Character] = ["-", "*", "_"]
        return marks.contains { mark in
            trimmed.count >= 3 && trimmed.allSatisfy { $0 == mark }
        }
    }

    private static func bulletMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let mark = trimmed.first, mark == "-" || mark == "*" || mark == "+" else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " || rest.first == "\t" || rest.isEmpty else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func numberedMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var digits = 0
        for character in trimmed {
            if character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let rest = trimmed.dropFirst(digits)
        guard rest.hasPrefix(". ") || rest == "." else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func quoteMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }

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
            if afterOpen.last != ")" {
                return String(text[..<open]) + String(afterOpen.dropFirst().prefix { $0 != "]" })
            }
            return text
        }
        if !afterOpen.contains("]") {
            return String(text[..<open]) + String(afterOpen.dropFirst())
        }
        return text
    }
}
