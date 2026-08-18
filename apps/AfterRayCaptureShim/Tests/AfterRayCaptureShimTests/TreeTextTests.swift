@testable import AfterRayCapturePolicy
import XCTest

/// The numbered-indented encoding from docs/event-capture-v2-plan.md §4. Every
/// assertion here is a promise to a model that will read this text with no
/// access to the tree it came from.
final class TreeTextTests: XCTestCase {
    // MARK: - Shape

    /// The plan's worked example, end to end.
    func testRendersTheNumberedIndentedExample() {
        let tree = CaptureTreeNode(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            title: "Feishu",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    title: "ContentsView",
                    children: [
                        CaptureTreeNode(
                            role: "AXButton",
                            title: "更多操作",
                            nodeDescription: "归档会话",
                            children: [CaptureTreeNode(role: "AXImage")]
                        ),
                        CaptureTreeNode(
                            role: "AXWebArea",
                            title: "messenger",
                            url: "file:///Applications/Lark.app/en-US.html"
                        ),
                    ]
                )
            ]
        )

        XCTAssertEqual(
            CaptureTreeText.render(tree).text,
            """
            0 standard window Feishu
            \t1 container ContentsView
            \t\t2 button (collapsed) 更多操作, Description: 归档会话
            \t\t3 HTML content messenger, URL: file:///Applications/Lark.app/en-US.html
            """
        )
    }

    func testDepthIsTabIndentation() {
        let tree = CaptureTreeNode(
            role: "AXWindow",
            title: "W",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    title: "G",
                    children: [CaptureTreeNode(role: "AXStaticText", value: "deep")]
                )
            ]
        )
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.lines.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rendered.text.split(separator: "\n").last, "\t\t2 text, Value: deep")
    }

    /// Numbers count *emitted* lines: a number that names no line could never be
    /// resolved by an `afterray://moment/<id>#el<N>` citation.
    func testNumbersAreDFSOverEmittedLinesOnly() {
        let hidden = CaptureTreeNode(
            role: "AXGroup",
            title: "Chrome",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    children: [
                        CaptureTreeNode(role: "AXGroup", children: [CaptureTreeNode(role: "AXImage")])
                    ]
                )
            ]
        )
        let tree = CaptureTreeNode(
            role: "AXWindow",
            title: "W",
            children: [hidden, CaptureTreeNode(role: "AXStaticText", value: "after")]
        )
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.lines.map(\.number), [0, 1, 2])
        XCTAssertEqual(rendered.lines[2].text, "2 text, Value: after")
    }

    func testSubtreeLineCountSpansTheEmittedDescendants() {
        let tree = CaptureTreeNode(
            role: "AXWindow",
            title: "W",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    title: "G",
                    children: [
                        CaptureTreeNode(role: "AXStaticText", value: "a"),
                        CaptureTreeNode(role: "AXStaticText", value: "b"),
                    ]
                ),
                CaptureTreeNode(role: "AXStaticText", value: "c"),
            ]
        )
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.lines.map(\.subtreeLineCount), [5, 3, 1, 1, 1])
    }

    func testASingleNodeTreeRenders() {
        let rendered = CaptureTreeText.render(CaptureTreeNode(role: "AXWindow", title: "Alone"))
        XCTAssertEqual(rendered.text, "0 standard window Alone")
        XCTAssertFalse(rendered.isEmpty)
        XCTAssertFalse(rendered.lines[0].collapsed, "a leaf has nothing to collapse")
    }

    // MARK: - Role vocabulary

    func testVocabularyIsHumanReadable() {
        let cases: [(String, String)] = [
            ("AXWindow", "standard window"),
            ("AXApplication", "application"),
            ("AXGroup", "container"),
            ("AXButton", "button"),
            ("AXWebArea", "HTML content"),
            ("AXStaticText", "text"),
            ("AXTextArea", "text input"),
            ("AXTextField", "text field"),
            ("AXTabGroup", "tab group"),
            ("AXLink", "link"),
            ("AXImage", "image"),
            ("AXCheckBox", "checkbox"),
            ("AXMenuItem", "menu item"),
            ("AXScrollArea", "scroll area"),
            ("AXTable", "table"),
            ("AXRow", "row"),
            ("AXCell", "cell"),
            ("AXToolbar", "toolbar"),
            ("AXSheet", "sheet"),
            ("AXHeading", "heading"),
        ]
        for (role, word) in cases {
            XCTAssertEqual(
                CaptureRoleVocabulary.word(role: role, subrole: nil),
                word,
                "\(role) should read as \(word)"
            )
        }
    }

    func testSubroleRefinesTheRoleWord() {
        XCTAssertEqual(
            CaptureRoleVocabulary.word(role: "AXRadioButton", subrole: "AXTabButton"),
            "tab",
            "a tab described as a radio button reads as a form"
        )
        XCTAssertEqual(
            CaptureRoleVocabulary.word(role: "AXTextField", subrole: "AXSecureTextField"),
            "secure text field"
        )
        XCTAssertEqual(CaptureRoleVocabulary.word(role: "AXWindow", subrole: "AXDialog"), "dialog")
        XCTAssertEqual(
            CaptureRoleVocabulary.word(role: "AXButton", subrole: "AXWidgetOfTheFuture"),
            "button",
            "an unknown subrole falls back to the role rather than vanishing"
        )
    }

    func testUnknownRolesPassThroughWithoutTheAXPrefix() {
        XCTAssertEqual(CaptureRoleVocabulary.word(role: "AXFooBar", subrole: nil), "foobar")
        XCTAssertEqual(
            CaptureRoleVocabulary.word(role: "CustomThing", subrole: nil),
            "customthing",
            "a role that never had an AX prefix keeps all of itself"
        )
        XCTAssertEqual(CaptureRoleVocabulary.word(role: nil, subrole: nil), "element")
        XCTAssertEqual(CaptureRoleVocabulary.word(role: "", subrole: nil), "element")
        XCTAssertEqual(CaptureRoleVocabulary.word(role: "AX", subrole: nil), "element")
    }

    // MARK: - Attributes

    func testAttributesAreInlinedInOrder() {
        let node = CaptureTreeNode(
            role: "AXWebArea",
            title: "Docs",
            nodeDescription: "the docs pane",
            value: "hello",
            url: "https://example.invalid/a",
            document: "file:///tmp/a.md"
        )
        XCTAssertEqual(
            CaptureTreeText.render(node).lines[0].text,
            "0 HTML content Docs, URL: https://example.invalid/a, "
                + "Document: file:///tmp/a.md, Description: the docs pane, Value: hello"
        )
    }

    func testAbsentAttributesAreOmitted() {
        XCTAssertEqual(
            CaptureTreeText.render(CaptureTreeNode(role: "AXGroup", title: "G")).lines[0].text,
            "0 container G"
        )
        XCTAssertEqual(
            CaptureTreeText.render(CaptureTreeNode(role: "AXGroup")).lines[0].text,
            "0 container",
            "an unlabelled node is just its role"
        )
        XCTAssertEqual(
            CaptureTreeText.render(CaptureTreeNode(role: "AXGroup", title: "   ")).lines[0].text,
            "0 container",
            "whitespace is not a label"
        )
    }

    func testDescriptionBecomesTheLabelWhenThereIsNoTitleAndIsNotRepeated() {
        let line = CaptureTreeText.render(
            CaptureTreeNode(role: "AXButton", nodeDescription: "Send message")
        ).lines[0]
        XCTAssertEqual(line.text, "0 button Send message")
        XCTAssertEqual(line.label, "Send message")
    }

    func testDocumentIsOmittedWhenItRepeatsTheURL() {
        let line = CaptureTreeText.render(
            CaptureTreeNode(role: "AXWebArea", url: "https://a.invalid/", document: "https://a.invalid/")
        ).lines[0]
        XCTAssertEqual(line.text, "0 HTML content, URL: https://a.invalid/")
    }

    func testFrameIsNotRendered() {
        let line = CaptureTreeText.render(
            CaptureTreeNode(
                role: "AXButton",
                title: "OK",
                frame: CaptureTreeFrame(x: 10, y: 20, width: 30, height: 40)
            )
        ).lines[0]
        XCTAssertEqual(line.text, "0 button OK", "coordinates are for cropping, not for reading")
    }

    // MARK: - Text hygiene

    func testWhitespaceIsCollapsed() {
        let line = CaptureTreeText.render(
            CaptureTreeNode(role: "AXStaticText", value: "  hello\n\tworld  \n\n  again ")
        ).lines[0]
        XCTAssertEqual(line.text, "0 text, Value: hello world again")
    }

    /// A newline inside a title would forge a tree line, so collapsing is a
    /// correctness rule, not cosmetics.
    func testEmbeddedNewlinesCannotForgeALine() {
        let tree = CaptureTreeNode(role: "AXWindow", title: "A\n\t9 button Fake")
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.lines.count, 1)
        XCTAssertFalse(rendered.text.contains("\n"))
        XCTAssertEqual(rendered.text, "0 standard window A 9 button Fake")
    }

    func testLongValuesAreClippedWithAnExplicitMarker() {
        let long = String(repeating: "a", count: CaptureTreeText.maxTextChars + 100)
        let line = CaptureTreeText.render(CaptureTreeNode(role: "AXTextArea", value: long)).lines[0]
        XCTAssertEqual(
            line.text,
            "0 text input, Value: " + String(repeating: "a", count: CaptureTreeText.maxTextChars)
                + CaptureTreeText.truncationMarker
        )
    }

    func testTextAtTheClipBoundaryIsLeftAlone() {
        let exact = String(repeating: "b", count: CaptureTreeText.maxTextChars)
        let line = CaptureTreeText.render(CaptureTreeNode(role: "AXTextArea", value: exact)).lines[0]
        XCTAssertFalse(line.text.contains(CaptureTreeText.truncationMarker))
        XCTAssertEqual(line.text, "0 text input, Value: " + exact)
    }

    func testLabelsAreClippedToo() {
        let long = String(repeating: "t", count: CaptureTreeText.maxTextChars + 1)
        let line = CaptureTreeText.render(CaptureTreeNode(role: "AXWindow", title: long)).lines[0]
        XCTAssertTrue(line.label.hasSuffix(CaptureTreeText.truncationMarker))
        XCTAssertEqual(line.label.count, CaptureTreeText.maxTextChars + CaptureTreeText.truncationMarker.count)
    }

    /// Measured: Chinese is the content that only ever arrives through values and
    /// labels (the key stream is pinyin fragments). Clipping counts characters,
    /// so a CJK value keeps 300 readable characters, not 100.
    func testCJKLabelsAndValuesSurviveIntact() {
        let tree = CaptureTreeNode(
            role: "AXWindow",
            title: "飞书",
            children: [
                CaptureTreeNode(role: "AXButton", title: "更多操作", nodeDescription: "归档会话"),
                CaptureTreeNode(role: "AXStaticText", value: "今天的会议纪要"),
            ]
        )
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.lines[0].label, "飞书")
        XCTAssertEqual(rendered.lines[1].text, "1 button 更多操作, Description: 归档会话")
        XCTAssertEqual(rendered.lines[2].text, "2 text, Value: 今天的会议纪要")

        let longCJK = String(repeating: "更", count: CaptureTreeText.maxTextChars + 1)
        let clipped = CaptureTreeText.render(CaptureTreeNode(role: "AXStaticText", value: longCJK))
        XCTAssertEqual(
            clipped.lines[0].text,
            "0 text, Value: " + String(repeating: "更", count: CaptureTreeText.maxTextChars)
                + CaptureTreeText.truncationMarker
        )
    }

    // MARK: - Collapsing

    func testACollapsedNodeHidesItsChildren() {
        let tree = CaptureTreeNode(
            role: "AXButton",
            title: "更多操作",
            children: [
                CaptureTreeNode(role: "AXImage"),
                CaptureTreeNode(role: "AXGroup", children: [CaptureTreeNode(role: "AXImage")]),
            ]
        )
        let rendered = CaptureTreeText.render(tree)
        XCTAssertEqual(rendered.text, "0 button (collapsed) 更多操作")
        XCTAssertTrue(rendered.lines[0].collapsed)
    }

    /// The Electron case: a chain of anonymous wrappers ending in decoration.
    func testADeepChainWithNoTextCollapsesToOneLine() {
        var chain = CaptureTreeNode(role: "AXImage")
        for _ in 0..<12 {
            chain = CaptureTreeNode(role: "AXGroup", children: [chain])
        }
        let tree = CaptureTreeNode(role: "AXWindow", title: "Feishu", children: [chain])
        XCTAssertEqual(CaptureTreeText.render(tree).text, "0 standard window (collapsed) Feishu")
    }

    func testCollapsedLabelLadderFallsThroughToADescendant() {
        // No title, no description on the chain top; the named container inside
        // is the only thing that can say what this is.
        let tree = CaptureTreeNode(
            role: "AXGroup",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    children: [
                        CaptureTreeNode(role: "AXGroup", title: "Sidebar", children: [
                            CaptureTreeNode(role: "AXImage")
                        ])
                    ]
                )
            ]
        )
        XCTAssertEqual(CaptureTreeText.render(tree).text, "0 container (collapsed) Sidebar")
    }

    func testCollapsedLabelPrefersTitleThenDescriptionThenDescendant() {
        let inner = CaptureTreeNode(role: "AXGroup", title: "Inner", children: [
            CaptureTreeNode(role: "AXImage")
        ])
        let withTitle = CaptureTreeNode(
            role: "AXGroup", title: "Outer", nodeDescription: "described", children: [inner]
        )
        let withDescription = CaptureTreeNode(
            role: "AXGroup", nodeDescription: "described", children: [inner]
        )
        let withNeither = CaptureTreeNode(role: "AXGroup", children: [inner])
        XCTAssertEqual(CaptureTreeText.render(withTitle).lines[0].label, "Outer")
        XCTAssertEqual(CaptureTreeText.render(withDescription).lines[0].label, "described")
        XCTAssertEqual(CaptureTreeText.render(withNeither).lines[0].label, "Inner")
    }

    func testTextAnywhereBelowKeepsTheSubtreeOpen() {
        let deep = CaptureTreeNode(
            role: "AXGroup",
            children: [
                CaptureTreeNode(
                    role: "AXGroup",
                    children: [
                        CaptureTreeNode(role: "AXGroup", children: [
                            CaptureTreeNode(role: "AXStaticText", value: "buried")
                        ])
                    ]
                )
            ]
        )
        let rendered = CaptureTreeText.render(deep)
        XCTAssertEqual(rendered.lines.count, 4, "one text node keeps the whole chain")
        XCTAssertTrue(rendered.text.hasSuffix("3 text, Value: buried"))
    }

    /// A named `AXGroup` is chrome, not content — otherwise Electron's container
    /// soup, where every third group has a title, never collapses at all. A
    /// named *button* is content, and holds its subtree open.
    func testChromeTitlesDoNotBlockCollapseButContentDoes() {
        let chrome = CaptureTreeNode(
            role: "AXGroup",
            title: "Wrapper",
            children: [
                CaptureTreeNode(role: "AXScrollArea", title: "Scroller", children: [
                    CaptureTreeNode(role: "AXImage")
                ])
            ]
        )
        XCTAssertEqual(CaptureTreeText.render(chrome).text, "0 container (collapsed) Wrapper")

        let content = CaptureTreeNode(
            role: "AXGroup",
            title: "Wrapper",
            children: [CaptureTreeNode(role: "AXButton", title: "Send")]
        )
        XCTAssertEqual(
            CaptureTreeText.render(content).text,
            """
            0 container Wrapper
            \t1 button Send
            """
        )
    }

    func testAValueOnAChromeNodeStillCountsAsContent() {
        let tree = CaptureTreeNode(
            role: "AXGroup",
            children: [CaptureTreeNode(role: "AXGroup", value: "typed here")]
        )
        XCTAssertEqual(
            CaptureTreeText.render(tree).text,
            """
            0 container
            \t1 container, Value: typed here
            """
        )
    }

    func testAURLBelowCountsAsContent() {
        let tree = CaptureTreeNode(
            role: "AXGroup",
            children: [CaptureTreeNode(role: "AXWebArea", url: "https://example.invalid/")]
        )
        XCTAssertEqual(CaptureTreeText.render(tree).lines.count, 2)
    }

    func testACollapsedNodeStillShowsItsOwnAttributes() {
        let tree = CaptureTreeNode(
            role: "AXTextArea",
            title: "Compose",
            value: "draft",
            children: [CaptureTreeNode(role: "AXGroup", children: [CaptureTreeNode(role: "AXImage")])]
        )
        XCTAssertEqual(
            CaptureTreeText.render(tree).text,
            "0 text input (collapsed) Compose, Value: draft",
            "the node's own content is not what collapsed"
        )
    }
}
