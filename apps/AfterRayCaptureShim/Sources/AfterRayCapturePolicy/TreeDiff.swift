/// The difference between two rendered trees, as the text a `diffFromPrevious`
/// artifact carries (docs/event-capture-v2-plan.md §4).
///
/// ```
/// Removed element IDs: 97-100, 103-137
/// ~0 standard window Feishu
/// ~	1 container ContentsView
/// +		34 HTML content messenger, URL: https://example.invalid/
/// ```
///
/// Three rules do all the work, and each exists for a measured reason:
///
/// - **Only changed paths are emitted.** Measured, a full tree is ~200 KB while
///   the diff between two consecutive ones has a 913 B median. Everything
///   unchanged outside a change path is the 199 KB nobody needs.
/// - **Ancestors of a change come along as `~` context.** A bare `+34 button
///   Send` is unlocatable; the numbers drift between frames (measured on
///   966/2,073 labels), so the path is the only durable answer to *where*.
/// - **Removals coalesce into one leading ID range list.** A closed panel takes
///   forty consecutive numbers with it; spelling out forty deleted lines would
///   cost more than the tree they came from.
package struct TreeDiff: Equatable, Sendable {
    package enum Marker: String, Equatable, Sendable {
        /// A node with no counterpart in the previous tree.
        case added = "+"
        /// A node whose text changed, or an unchanged ancestor kept as context.
        case changed = "~"
    }

    package struct Line: Equatable, Sendable {
        package let marker: Marker
        package let depth: Int
        /// The node's number **in the current tree**.
        package let number: Int
        /// Number and body, without marker or indentation.
        package let text: String
    }

    /// Numbers from the **previous** tree, ascending. They index the frame the
    /// diff was taken against, which is the only frame in which they resolve.
    package let removedIds: [Int]
    package let lines: [Line]

    /// Nothing moved. The caller skips emission entirely — an artifact saying
    /// "no change" costs storage and tells a reader nothing a missing artifact
    /// would not.
    package var isEmpty: Bool { lines.isEmpty && removedIds.isEmpty }

    /// The rendered diff. Markers sit at the left edge, before the indentation,
    /// so every marker in the body lines up in one column; every emitted line
    /// carries exactly one, so the indentation stays readable as a tree.
    package var text: String {
        var out: [String] = []
        if !removedIds.isEmpty {
            out.append("Removed element IDs: " + Self.formatRanges(removedIds))
        }
        for line in lines {
            out.append(line.marker.rawValue + String(repeating: "\t", count: line.depth) + line.text)
        }
        return out.joined(separator: "\n")
    }

    /// Collapses ascending numbers into `97-100, 103-137`; a run of one stays a
    /// bare number.
    static func formatRanges(_ ids: [Int]) -> String {
        var ranges: [String] = []
        var start: Int?
        var previous: Int?
        for id in ids {
            if let last = previous, id == last + 1 {
                previous = id
                continue
            }
            if let begin = start, let end = previous {
                ranges.append(begin == end ? "\(begin)" : "\(begin)-\(end)")
            }
            start = id
            previous = id
        }
        if let begin = start, let end = previous {
            ranges.append(begin == end ? "\(begin)" : "\(begin)-\(end)")
        }
        return ranges.joined(separator: ", ")
    }

    // MARK: - Computation

    /// Aligns two rendered trees and reports what changed.
    ///
    /// Alignment is structural, not textual: children of two matched parents are
    /// paired by (role, label) in sibling order, so duplicate siblings — a list
    /// of twenty identically-labelled rows — pair first-with-first and stay
    /// stable when one is inserted in the middle. A second pass pairs the
    /// leftovers by role alone, which is what turns a renamed node into one `~`
    /// line instead of a removal plus an addition.
    package static func between(previous: RenderedTree, current: RenderedTree) -> TreeDiff {
        let prev = Indexed(previous)
        let curr = Indexed(current)

        var markers: [Int: Marker] = [:]
        var removed: [Int] = []

        if prev.tree.lines.isEmpty {
            // No baseline: everything is new.
            if let root = curr.tree.lines.first { markers[root.number] = .added }
        } else if curr.tree.lines.isEmpty {
            if let root = prev.tree.lines.first { removed.append(contentsOf: prev.numbers(of: root.number)) }
        } else if prev.tree.lines[0].role == curr.tree.lines[0].role {
            walk(prevIndex: 0, currIndex: 0, prev: prev, curr: curr, markers: &markers, removed: &removed)
        } else {
            // Different roots are different trees; the caller should have sent a
            // keyframe. Report it honestly rather than inventing an alignment.
            removed.append(contentsOf: prev.numbers(of: 0))
            markers[0] = .added
        }

        return TreeDiff(
            removedIds: removed.sorted(),
            lines: emit(markers: markers, curr: curr)
        )
    }

    /// Pairs one matched node's children, recording changes and recursing.
    private static func walk(
        prevIndex: Int,
        currIndex: Int,
        prev: Indexed,
        curr: Indexed,
        markers: inout [Int: Marker],
        removed: inout [Int]
    ) {
        if prev.tree.lines[prevIndex].body != curr.tree.lines[currIndex].body {
            markers[currIndex] = .changed
        }

        let prevChildren = prev.children[prevIndex]
        let currChildren = curr.children[currIndex]
        var takenPrev = Set<Int>()
        var pairs: [(Int, Int)] = []
        var unmatchedCurr: [Int] = []

        // Pass 1 — exact identity, in sibling order.
        var byKey: [String: [Int]] = [:]
        for child in prevChildren { byKey[prev.key(child), default: []].append(child) }
        for child in currChildren {
            let key = curr.key(child)
            if var queue = byKey[key], !queue.isEmpty {
                let match = queue.removeFirst()
                byKey[key] = queue
                takenPrev.insert(match)
                pairs.append((match, child))
            } else {
                unmatchedCurr.append(child)
            }
        }

        // Pass 2 — same role, different label: a rename, not a replacement.
        var byRole: [String: [Int]] = [:]
        for child in prevChildren where !takenPrev.contains(child) {
            byRole[prev.tree.lines[child].role ?? "", default: []].append(child)
        }
        var stillUnmatched: [Int] = []
        for child in unmatchedCurr {
            let role = curr.tree.lines[child].role ?? ""
            if var queue = byRole[role], !queue.isEmpty {
                let match = queue.removeFirst()
                byRole[role] = queue
                takenPrev.insert(match)
                pairs.append((match, child))
            } else {
                stillUnmatched.append(child)
            }
        }

        for child in prevChildren where !takenPrev.contains(child) {
            removed.append(contentsOf: prev.numbers(of: child))
        }
        for child in stillUnmatched {
            markers[child] = .added
        }
        for (prevChild, currChild) in pairs {
            walk(
                prevIndex: prevChild,
                currIndex: currChild,
                prev: prev,
                curr: curr,
                markers: &markers,
                removed: &removed
            )
        }
    }

    /// Turns per-node markers into the emitted line list: added subtrees whole,
    /// changed nodes, and every ancestor of either as context.
    private static func emit(markers: [Int: Marker], curr: Indexed) -> [Line] {
        guard !markers.isEmpty else { return [] }
        var resolved: [Int: Marker] = [:]
        for (index, marker) in markers {
            switch marker {
            case .added:
                // An added node arrives with its whole subtree; the children are
                // new too, and a `+` parent with no body is not readable.
                let line = curr.tree.lines[index]
                for offset in 0..<line.subtreeLineCount {
                    resolved[index + offset] = .added
                }
            case .changed:
                resolved[index] = .changed
            }
            var parent = curr.tree.lines[index].parent
            while let ancestor = parent {
                if resolved[ancestor] == nil { resolved[ancestor] = .changed }
                parent = curr.tree.lines[ancestor].parent
            }
        }
        return curr.tree.lines.compactMap { line in
            guard let marker = resolved[line.number] else { return nil }
            return Line(marker: marker, depth: line.depth, number: line.number, text: line.text)
        }
    }

    /// A rendered tree with its parent links inverted, so alignment can ask for
    /// a node's children without re-walking the line list.
    private struct Indexed {
        let tree: RenderedTree
        let children: [[Int]]

        init(_ tree: RenderedTree) {
            self.tree = tree
            var children = [[Int]](repeating: [], count: tree.lines.count)
            for line in tree.lines {
                if let parent = line.parent { children[parent].append(line.number) }
            }
            self.children = children
        }

        func key(_ index: Int) -> String {
            let line = tree.lines[index]
            return (line.role ?? "") + "\u{1}" + line.label
        }

        /// Every number the node's emitted subtree occupies — contiguous,
        /// because numbering is DFS over emitted lines.
        func numbers(of index: Int) -> [Int] {
            let line = tree.lines[index]
            return Array(line.number..<(line.number + line.subtreeLineCount))
        }
    }
}
