@testable import AfterRayCapturePolicy
import XCTest

/// The `diffFromPrevious` encoding from docs/event-capture-v2-plan.md §4.
final class TreeDiffTests: XCTestCase {
    // MARK: - Fixtures

    /// A window with a body of three text nodes — small enough to reason about,
    /// deep enough that ancestor context has something to say.
    private func window(_ texts: [String], title: String = "Feishu") -> CaptureTreeNode {
        CaptureTreeNode(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: title,
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    title: "Body",
                    children: texts.map { CaptureTreeNode(role: "AXStaticText", value: $0) }
                )
            ]
        )
    }

    private func diff(_ previous: CaptureTreeNode, _ current: CaptureTreeNode) -> TreeDiff {
        TreeDiff.between(
            previous: CaptureTreeText.render(previous),
            current: CaptureTreeText.render(current)
        )
    }

    // MARK: - Stillness

    func testAnIdenticalTreeProducesNothing() {
        let result = diff(window(["one", "two"]), window(["one", "two"]))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(result.text, "")
    }

    // MARK: - Changes

    /// The round trip the encoding exists for: render, let one value move, and
    /// read back one changed line that is still locatable.
    func testAChangedValueIsOneLineWithItsAncestorsAsContext() {
        let result = diff(window(["one", "two"]), window(["one", "three"]))
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(
            result.text,
            """
            ~0 standard window Feishu
            ~\t1 container Body
            ~\t\t3 text, Value: three
            """
        )
        XCTAssertEqual(result.lines.map(\.marker), [.changed, .changed, .changed])
    }

    func testUnchangedSubtreesOutsideTheChangePathAreOmitted() {
        let previous = CaptureTreeNode(
            role: "AXWindow",
            title: "W",
            children: [
                CaptureTreeNode(role: "AXGroup", title: "Left", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "untouched"),
                    CaptureTreeNode(role: "AXStaticText", value: "also untouched"),
                ]),
                CaptureTreeNode(role: "AXGroup", title: "Right", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "before")
                ]),
            ]
        )
        let current = CaptureTreeNode(
            role: "AXWindow",
            title: "W",
            children: [
                CaptureTreeNode(role: "AXGroup", title: "Left", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "untouched"),
                    CaptureTreeNode(role: "AXStaticText", value: "also untouched"),
                ]),
                CaptureTreeNode(role: "AXGroup", title: "Right", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "after")
                ]),
            ]
        )
        let result = diff(previous, current)
        XCTAssertEqual(
            result.lines.map(\.number),
            [0, 4, 5],
            "the whole Left subtree stays out of the diff"
        )
        XCTAssertEqual(
            result.text,
            """
            ~0 standard window W
            ~\t4 container Right
            ~\t\t5 text, Value: after
            """
        )
    }

    func testAChangedLabelIsAChangeNotAReplacement() {
        let previous = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [CaptureTreeNode(role: "AXButton", title: "Send")]
        )
        let current = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [CaptureTreeNode(role: "AXButton", title: "Sending…")]
        )
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [], "the same button, renamed")
        XCTAssertEqual(result.lines.map(\.marker), [.changed, .changed])
        XCTAssertEqual(result.lines.last?.text, "1 button Sending…")
    }

    func testTheRootItselfCanBeTheChange() {
        let result = diff(window(["one"], title: "Feishu"), window(["one"], title: "Feishu — 2 new"))
        XCTAssertEqual(result.lines.map(\.number), [0])
        XCTAssertEqual(result.lines[0].text, "0 standard window Feishu — 2 new")
    }

    // MARK: - Additions

    func testAnAddedNodeArrivesWithItsWholeSubtree() {
        let previous = window(["one"])
        var current = window(["one"])
        current.children[0].children.append(
            CaptureTreeNode(role: "AXGroup", title: "Toast", children: [
                CaptureTreeNode(role: "AXStaticText", value: "Saved"),
                CaptureTreeNode(role: "AXButton", title: "Undo"),
            ])
        )
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(
            result.text,
            """
            ~0 standard window Feishu
            ~\t1 container Body
            +\t\t3 container Toast
            +\t\t\t4 text, Value: Saved
            +\t\t\t5 button Undo
            """
        )
    }

    func testAnEmptyPreviousTreeMakesEverythingAdded() {
        let result = TreeDiff.between(
            previous: RenderedTree(lines: []),
            current: CaptureTreeText.render(window(["one"]))
        )
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(result.lines.map(\.marker), [.added, .added, .added])
        XCTAssertEqual(result.lines.map(\.number), [0, 1, 2])
    }

    /// Different roots mean the caller diffed across a window switch, which the
    /// keyframe policy exists to prevent. Report it honestly instead of
    /// inventing an alignment between two unrelated trees.
    func testDifferentRootsReplaceTheWholeTree() {
        let previous = window(["one"])
        let current = CaptureTreeNode(
            role: "AXApplication", title: "Xcode",
            children: [CaptureTreeNode(role: "AXStaticText", value: "hi")]
        )
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [0, 1, 2])
        XCTAssertEqual(result.lines.map(\.marker), [.added, .added])
    }

    // MARK: - Removals

    func testRemovalsCoalesceIntoOneLeadingLine() {
        let previous = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [
                CaptureTreeNode(role: "AXGroup", title: "Panel", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "a"),
                    CaptureTreeNode(role: "AXStaticText", value: "b"),
                ]),
                CaptureTreeNode(role: "AXGroup", title: "Main", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "c")
                ]),
            ]
        )
        var current = previous
        current.children.removeFirst()

        let result = diff(previous, current)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.removedIds, [1, 2, 3], "the panel and both of its texts")
        XCTAssertEqual(
            result.text,
            "Removed element IDs: 1-3",
            "a pure removal needs no body: the IDs are the whole message"
        )
    }

    func testARemovalAndAChangeShareOneDiff() {
        let previous = window(["one", "two", "three"])
        let current = window(["one", "changed"])
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [4], "the third text is gone")
        XCTAssertEqual(
            result.text,
            """
            Removed element IDs: 4
            ~0 standard window Feishu
            ~\t1 container Body
            ~\t\t3 text, Value: changed
            """
        )
    }

    func testAnEmptyCurrentTreeRemovesEverything() {
        let result = TreeDiff.between(
            previous: CaptureTreeText.render(window(["one"])),
            current: RenderedTree(lines: [])
        )
        XCTAssertEqual(result.removedIds, [0, 1, 2])
        XCTAssertEqual(result.lines, [])
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Removed ID ranges

    func testRangesMergeAdjacentIDsAndKeepSingletons() {
        XCTAssertEqual(
            TreeDiff.formatRanges([97, 98, 99, 100, 103, 104, 105]),
            "97-100, 103-105"
        )
        XCTAssertEqual(TreeDiff.formatRanges([5]), "5")
        XCTAssertEqual(TreeDiff.formatRanges([1, 3, 5]), "1, 3, 5")
        XCTAssertEqual(TreeDiff.formatRanges([1, 2]), "1-2")
        XCTAssertEqual(TreeDiff.formatRanges([]), "")
        XCTAssertEqual(TreeDiff.formatRanges([0, 1, 2, 4, 6, 7]), "0-2, 4, 6-7")
    }

    func testRemovedIDsAreSortedEvenWhenSubtreesLeaveOutOfOrder() {
        let previous = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [
                CaptureTreeNode(role: "AXGroup", title: "A", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "a")
                ]),
                CaptureTreeNode(role: "AXGroup", title: "Keep", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "k")
                ]),
                CaptureTreeNode(role: "AXGroup", title: "B", children: [
                    CaptureTreeNode(role: "AXStaticText", value: "b")
                ]),
            ]
        )
        var current = previous
        current.children = [current.children[1]]
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [1, 2, 5, 6])
        XCTAssertEqual(result.text, "Removed element IDs: 1-2, 5-6")
    }

    // MARK: - Alignment

    /// Distinct labels align across an insertion, so a new row in the middle of
    /// a list costs one `+` line and nothing else.
    func testDistinctSiblingsAlignAcrossAnInsertion() {
        let previous = CaptureTreeNode(
            role: "AXList", title: "Rooms",
            children: ["Alpha", "Beta", "Gamma"].map {
                CaptureTreeNode(role: "AXRow", title: $0)
            }
        )
        let current = CaptureTreeNode(
            role: "AXList", title: "Rooms",
            children: ["Alpha", "Delta", "Beta", "Gamma"].map {
                CaptureTreeNode(role: "AXRow", title: $0)
            }
        )
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(
            result.text,
            """
            ~0 list Rooms
            +\t2 row Delta
            """
        )
    }

    /// Duplicate siblings — twenty identically-labelled rows — pair first with
    /// first, so one moving value reports one change and not twenty.
    func testDuplicateSiblingsPairInOrder() {
        func rows(_ values: [String]) -> CaptureTreeNode {
            CaptureTreeNode(
                role: "AXList", title: "Rows",
                children: values.map {
                    CaptureTreeNode(role: "AXRow", title: "Row", value: $0)
                }
            )
        }
        let result = diff(rows(["a", "b", "c", "d"]), rows(["a", "z", "c", "d"]))
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(
            result.text,
            """
            ~0 list Rows
            ~\t2 row Row, Value: z
            """
        )
    }

    func testDuplicateSiblingsAppendReportsOnlyTheNewOne() {
        func rows(_ count: Int) -> CaptureTreeNode {
            CaptureTreeNode(
                role: "AXList", title: "Rows",
                children: (0..<count).map { _ in CaptureTreeNode(role: "AXRow", title: "Row") }
            )
        }
        let result = diff(rows(3), rows(4))
        XCTAssertEqual(result.lines.map(\.marker), [.changed, .added])
        XCTAssertEqual(result.lines.last?.number, 4, "the trailing row is the new one")
    }

    /// Alignment is scoped to a parent: two subtrees can hold identically
    /// labelled nodes without borrowing each other's.
    func testAlignmentDoesNotCrossParents() {
        func tree(left: String, right: String) -> CaptureTreeNode {
            CaptureTreeNode(
                role: "AXWindow", title: "W",
                children: [
                    CaptureTreeNode(role: "AXGroup", title: "Left", children: [
                        CaptureTreeNode(role: "AXStaticText", value: left)
                    ]),
                    CaptureTreeNode(role: "AXGroup", title: "Right", children: [
                        CaptureTreeNode(role: "AXStaticText", value: right)
                    ]),
                ]
            )
        }
        let result = diff(tree(left: "a", right: "b"), tree(left: "b", right: "a"))
        XCTAssertEqual(result.removedIds, [])
        XCTAssertEqual(result.lines.map(\.number), [0, 1, 2, 3, 4])
        XCTAssertEqual(
            result.lines.filter { $0.marker == .changed }.map(\.number),
            [0, 1, 2, 3, 4],
            "both sides changed in place; nothing moved between the groups"
        )
    }

    func testARoleChangeIsAReplacementNotAChange() {
        let previous = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [CaptureTreeNode(role: "AXButton", title: "Go")]
        )
        let current = CaptureTreeNode(
            role: "AXWindow", title: "W",
            children: [CaptureTreeNode(role: "AXStaticText", title: "Go")]
        )
        let result = diff(previous, current)
        XCTAssertEqual(result.removedIds, [1])
        XCTAssertEqual(result.lines.map(\.marker), [.changed, .added])
    }

    /// A collapsed subtree is one line to the diff too — the hidden children can
    /// never be reported as changed, because they were never numbered.
    func testCollapsedSubtreesDiffAsOneLine() {
        func icon(_ label: String) -> CaptureTreeNode {
            CaptureTreeNode(
                role: "AXWindow", title: "W",
                children: [
                    CaptureTreeNode(role: "AXButton", title: label, children: [
                        CaptureTreeNode(role: "AXImage"),
                        CaptureTreeNode(role: "AXGroup", children: [CaptureTreeNode(role: "AXImage")]),
                    ])
                ]
            )
        }
        let result = diff(icon("Mute"), icon("Unmute"))
        XCTAssertEqual(
            result.text,
            """
            ~0 standard window W
            ~\t1 button (collapsed) Unmute
            """
        )
    }

    // MARK: - Format

    func testMarkersSitBeforeTheIndentationSoTheyLineUp() {
        let previous = window(["one", "two"])
        var current = window(["one", "two"])
        current.children[0].children[1] = CaptureTreeNode(role: "AXStaticText", value: "changed")
        current.children[0].children.append(CaptureTreeNode(role: "AXButton", title: "New"))
        let lines = diff(previous, current).text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        for line in lines {
            let marker = line.prefix(1)
            XCTAssertTrue(marker == "~" || marker == "+", "every emitted line carries exactly one marker")
            XCTAssertFalse(line.dropFirst().hasPrefix(" "), "indentation is tabs, so markers align")
        }
    }
}
