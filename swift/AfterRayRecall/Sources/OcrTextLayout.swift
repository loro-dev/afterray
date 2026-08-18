import CoreGraphics
import CoreText
import Foundation

/// A caret position in the laid-out text: which line, and how many characters
/// into it. `character == characters.count` is the caret past the last glyph,
/// which is what a drag off the right edge of a line selects.
struct OcrTextPosition: Equatable, Comparable, Sendable {
    var line: Int
    var character: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line ? lhs.character < rhs.character : lhs.line < rhs.line
    }
}

/// An ordered selection. Built from an anchor and a head so a backwards drag
/// produces the same range as the forwards one.
struct OcrTextRange: Equatable, Sendable {
    let start: OcrTextPosition
    let end: OcrTextPosition

    init(anchor: OcrTextPosition, head: OcrTextPosition) {
        if head < anchor {
            start = head
            end = anchor
        } else {
            start = anchor
            end = head
        }
    }

    var isEmpty: Bool { start == end }
}

/// One recognized line placed on the picture as it is actually drawn.
struct OcrTextLine: Equatable, Sendable {
    let text: String
    /// Kept alongside `text` because every hit test and slice indexes by
    /// character offset; recomputing `String.Index` per mouse event is the one
    /// thing in this path that would show up in a profile.
    let characters: [Character]
    /// y measured down from the top, like SwiftUI and a flipped `NSView` —
    /// `OcrHighlight.rect` has already flipped Vision's bottom-left origin.
    let rect: CGRect
}

/// OCR boxes turned into something a pointer can select.
///
/// Deliberately free of AppKit and of CoreText: the boxes alone answer "is the
/// pointer over text", "which line", and "what string did the user select".
/// Glyph metrics are needed only to resolve a column *inside* a line, and those
/// are built lazily by the view (`OcrCaretMetrics`).
struct OcrTextLayout: Equatable, Sendable {
    static let empty = OcrTextLayout(lines: [])

    let lines: [OcrTextLine]

    var isEmpty: Bool { lines.isEmpty }

    static func build(regions: [OcrRegion], contentRect: CGRect) -> OcrTextLayout {
        guard contentRect.width > 0, contentRect.height > 0 else { return .empty }
        let placed = regions.compactMap { region -> OcrTextLine? in
            let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = OcrHighlight.rect(for: region, in: contentRect)
            guard
                rect.width > 0, rect.height > 0,
                rect.origin.x.isFinite, rect.origin.y.isFinite
            else { return nil }
            return OcrTextLine(text: text, characters: Array(text), rect: rect)
        }
        return OcrTextLayout(lines: readingOrder(placed))
    }

    /// Vision returns observations in no useful order, and copy quality is
    /// entirely a function of fixing that: lines are grouped into rows by
    /// vertical proximity, then read left to right within a row.
    ///
    /// Side-by-side columns collapse into shared rows. macOS Live Text has the
    /// same limitation; a capture is a screenshot, not a document, and a column
    /// detector is wrong in different and less predictable ways.
    static func readingOrder(_ lines: [OcrTextLine]) -> [OcrTextLine] {
        let sorted = lines.sorted { first, second in
            if first.rect.midY != second.rect.midY { return first.rect.midY < second.rect.midY }
            return first.rect.minX < second.rect.minX
        }
        var rows: [[OcrTextLine]] = []
        // The row's anchor is its first line, not a running average: an average
        // drifts down a long row of slightly descending boxes and eventually
        // swallows the row below it.
        var anchorY: CGFloat = 0
        for line in sorted {
            if let row = rows.last, let first = row.first {
                let tolerance = min(line.rect.height, first.rect.height) * 0.5
                if abs(line.rect.midY - anchorY) <= tolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
            anchorY = line.rect.midY
        }
        return rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// Strict: is the point on a glyph box? Drives the I-beam and the hit test
    /// that decides between selecting text and scrubbing the timeline, so it
    /// must not answer yes for the empty desktop around the words.
    func lineIndex(at point: CGPoint, padding: CGFloat) -> Int? {
        lines.firstIndex { $0.rect.insetBy(dx: -padding, dy: -padding).contains(point) }
    }

    /// Lenient: the line a drag at this point should extend to. A pointer in
    /// the margin still has to resolve to something, or the selection freezes
    /// the moment the cursor leaves a box.
    func nearestLineIndex(at point: CGPoint) -> Int? {
        var bestIndex: Int?
        var bestVertical = CGFloat.greatestFiniteMagnitude
        var bestHorizontal = CGFloat.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            let vertical = Self.distance(from: point.y, min: line.rect.minY, max: line.rect.maxY)
            let horizontal = Self.distance(from: point.x, min: line.rect.minX, max: line.rect.maxX)
            let closer = vertical < bestVertical
                || (vertical == bestVertical && horizontal < bestHorizontal)
            guard closer else { continue }
            bestIndex = index
            bestVertical = vertical
            bestHorizontal = horizontal
        }
        return bestIndex
    }

    private static func distance(from value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        if value < lower { return lower - value }
        if value > upper { return value - upper }
        return 0
    }

    func clamped(_ position: OcrTextPosition) -> OcrTextPosition {
        guard !lines.isEmpty else { return OcrTextPosition(line: 0, character: 0) }
        let line = min(max(position.line, 0), lines.count - 1)
        let character = min(max(position.character, 0), lines[line].characters.count)
        return OcrTextPosition(line: line, character: character)
    }

    var fullRange: OcrTextRange? {
        guard let last = lines.last else { return nil }
        return OcrTextRange(
            anchor: OcrTextPosition(line: 0, character: 0),
            head: OcrTextPosition(line: lines.count - 1, character: last.characters.count)
        )
    }

    func wordRange(at position: OcrTextPosition) -> OcrTextRange {
        let start = clamped(position)
        guard lines.indices.contains(start.line) else { return OcrTextRange(anchor: start, head: start) }
        let line = lines[start.line]
        guard !line.characters.isEmpty else { return OcrTextRange(anchor: start, head: start) }
        let target = min(start.character, line.characters.count - 1)
        // Word segmentation, not whitespace splitting: a Chinese line has no
        // spaces to split on, and double-clicking it should not select the
        // whole paragraph.
        var result = OcrTextRange(
            anchor: OcrTextPosition(line: start.line, character: target),
            head: OcrTextPosition(line: start.line, character: target + 1)
        )
        line.text.enumerateSubstrings(
            in: line.text.startIndex..<line.text.endIndex,
            options: .byWords
        ) { _, range, _, stop in
            let lower = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let upper = line.text.distance(from: line.text.startIndex, to: range.upperBound)
            guard lower <= target, target < upper else { return }
            result = OcrTextRange(
                anchor: OcrTextPosition(line: start.line, character: lower),
                head: OcrTextPosition(line: start.line, character: upper)
            )
            stop = true
        }
        return result
    }

    func lineRange(at position: OcrTextPosition) -> OcrTextRange {
        let start = clamped(position)
        guard lines.indices.contains(start.line) else { return OcrTextRange(anchor: start, head: start) }
        return OcrTextRange(
            anchor: OcrTextPosition(line: start.line, character: 0),
            head: OcrTextPosition(line: start.line, character: lines[start.line].characters.count)
        )
    }

    /// What ⌘C puts on the pasteboard. Always the recognized string, never a
    /// guess reconstructed from the boxes.
    func string(for range: OcrTextRange) -> String {
        guard
            !range.isEmpty,
            lines.indices.contains(range.start.line),
            lines.indices.contains(range.end.line)
        else { return "" }
        if range.start.line == range.end.line {
            return slice(lines[range.start.line], from: range.start.character, to: range.end.character)
        }
        var parts = [slice(lines[range.start.line], from: range.start.character, to: nil)]
        if range.start.line + 1 < range.end.line {
            for index in (range.start.line + 1)..<range.end.line {
                parts.append(lines[index].text)
            }
        }
        parts.append(slice(lines[range.end.line], from: 0, to: range.end.character))
        return parts.joined(separator: "\n")
    }

    private func slice(_ line: OcrTextLine, from: Int, to: Int?) -> String {
        let count = line.characters.count
        let lower = min(max(from, 0), count)
        let upper = min(max(to ?? count, lower), count)
        return String(line.characters[lower..<upper])
    }

    /// `caretX` is supplied by the view, which owns the lazily built CoreText
    /// metrics — a frame nobody selects on never measures a glyph.
    func selectionRects(for range: OcrTextRange, caretX: (OcrTextPosition) -> CGFloat) -> [CGRect] {
        guard
            !range.isEmpty,
            lines.indices.contains(range.start.line),
            lines.indices.contains(range.end.line)
        else { return [] }
        var rects: [CGRect] = []
        for index in range.start.line...range.end.line {
            let line = lines[index]
            let left = index == range.start.line
                ? caretX(OcrTextPosition(line: index, character: range.start.character))
                : line.rect.minX
            let right = index == range.end.line
                ? caretX(OcrTextPosition(line: index, character: range.end.character))
                : line.rect.maxX
            guard right > left else { continue }
            rects.append(
                CGRect(x: left, y: line.rect.minY, width: right - left, height: line.rect.height)
            )
        }
        return rects
    }
}

/// Glyph geometry for one OCR line.
///
/// A box is all Vision gives us, so the line is typeset once and then scaled
/// horizontally onto that box. Advances scale linearly with point size, so the
/// size chosen here cancels out of the result — what the approximation is
/// really sensitive to is the *font*, and even then only the highlight moves:
/// the copied string is the recognized text regardless.
enum OcrCaretMetrics {
    /// x for every caret index `0...characters.count`, in view coordinates.
    static func caretOffsets(for line: OcrTextLine) -> [CGFloat] {
        let count = line.characters.count
        guard count > 0, line.rect.width > 0 else { return [line.rect.minX] }
        let size = max(line.rect.height, 1)
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: line.text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let typeset = CTLineCreateWithAttributedString(attributed)
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(typeset, nil, nil, nil))
        let scale = typographicWidth > 0 ? line.rect.width / typographicWidth : 0

        var offsets: [CGFloat] = [line.rect.minX]
        offsets.reserveCapacity(count + 1)
        var utf16Offset = 0
        for character in line.characters {
            utf16Offset += character.utf16.count
            let raw = CTLineGetOffsetForStringIndex(typeset, CFIndex(utf16Offset), nil)
            // Monotonic by construction for the LTR text this handles; clamped
            // anyway so a surprising font can never produce a negative-width
            // selection rect.
            offsets.append(max(offsets[offsets.count - 1], line.rect.minX + raw * scale))
        }
        // Pin the tail: a drag past the end of a line must select all of it,
        // whatever trailing whitespace did to the typographic width.
        offsets[count] = max(offsets[count - 1], line.rect.maxX)
        return offsets
    }

    /// The caret index nearest `x` — the same "nearer of the two boundaries"
    /// rule a text view uses, so a click lands where the user aimed.
    static func characterIndex(forX x: CGFloat, offsets: [CGFloat]) -> Int {
        guard offsets.count > 1 else { return 0 }
        if x <= offsets[0] { return 0 }
        if x >= offsets[offsets.count - 1] { return offsets.count - 1 }
        var low = 0
        var high = offsets.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if offsets[mid] <= x { low = mid } else { high = mid }
        }
        return (x - offsets[low]) <= (offsets[high] - x) ? low : high
    }
}
