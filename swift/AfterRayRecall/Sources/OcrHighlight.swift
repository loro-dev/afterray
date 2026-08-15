import CoreGraphics
import Foundation

/// Maps Vision's OCR boxes onto the picture as it is actually drawn.
///
/// Two conversions have to be right or the boxes land on the wrong words:
///
/// 1. The still is displayed with `.resizeAspect`, so it is letterboxed inside
///    the view. Boxes are relative to the *picture*, not the view.
/// 2. Vision's unit square has its origin at the bottom left; SwiftUI's is at
///    the top left. The y axis flips.
public enum OcrHighlight {
    /// Where a `pixelSize` image lands inside `viewSize` under `.resizeAspect`.
    public static func contentRect(pixelSize: CGSize, viewSize: CGSize) -> CGRect {
        guard
            pixelSize.width > 0, pixelSize.height > 0,
            viewSize.width > 0, viewSize.height > 0
        else { return .zero }

        let scale = min(viewSize.width / pixelSize.width, viewSize.height / pixelSize.height)
        let width = pixelSize.width * scale
        let height = pixelSize.height * scale
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Vision unit-square box → points in the coordinate space of the view that
    /// `contentRect` was computed for.
    public static func rect(for region: OcrRegion, in contentRect: CGRect) -> CGRect {
        guard contentRect.width > 0, contentRect.height > 0 else { return .zero }
        let width = CGFloat(region.width) * contentRect.width
        let height = CGFloat(region.height) * contentRect.height
        // Vision measures y up from the bottom edge of the image.
        let topFromImageTop = (1 - CGFloat(region.y) - CGFloat(region.height)) * contentRect.height
        return CGRect(
            x: contentRect.minX + CGFloat(region.x) * contentRect.width,
            y: contentRect.minY + topFromImageTop,
            width: width,
            height: height
        )
    }

    /// Regions whose text contains any token of `query`.
    ///
    /// Returns nothing rather than guessing when no token matches. Drawing a
    /// confident-looking box around text the query did not hit is worse than
    /// drawing none: the whole point is to show *where* the match is.
    public static func matching(regions: [OcrRegion], query: String) -> [OcrRegion] {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return [] }
        return regions.filter { region in
            tokens.contains { token in
                region.text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Splits a query into searchable tokens, dropping FTS5 syntax the user may
    /// have typed (`AND`, `"quoted"`, `prefix*`) so it does not leak into a
    /// literal substring test.
    static func queryTokens(_ query: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t\n\r\"'()*:^-+")
        return query
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard !token.isEmpty else { return false }
                // A lone Latin letter matches nearly every region and would
                // light up the whole screen; a lone CJK character is a real query.
                if token.count == 1, token.unicodeScalars.allSatisfy(\.isASCII) { return false }
                let upper = token.uppercased()
                return upper != "AND" && upper != "OR" && upper != "NOT" && upper != "NEAR"
            }
    }
}
