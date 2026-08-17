import XCTest
@testable import AfterRayRecall

final class StreamingMarkdownTests: XCTestCase {
    func testUnclosedFenceStaysACodeBlockAndDoesNotSwallowLaterText() {
        let source = """
        Before

        ```swift
        func foo() {
            print("hi
        """
        let blocks = StreamingMarkdown.blocks(from: source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .markdown("Before"))
        guard case .code(let language, let text, let closed) = blocks[1] else {
            return XCTFail("expected an unclosed code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertFalse(closed)
        XCTAssertTrue(text.contains("func foo()"))
        XCTAssertFalse(text.contains("```"))
    }

    func testClosedFenceThenParagraph() {
        let source = """
        ```
        a
        ```
        after
        """
        let blocks = StreamingMarkdown.blocks(from: source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .code(language: "", text: "a", closed: true))
        XCTAssertEqual(blocks[1], .markdown("after"))
    }

    func testPartialListRendersCompletedItems() {
        let blocks = StreamingMarkdown.blocks(from: "- one\n- two\n- ")
        XCTAssertEqual(blocks, [.markdown("- one\n- two\n- ")])
    }

    func testNumberedListAndHeadingSurviveHalfwayThrough() {
        let blocks = StreamingMarkdown.blocks(from: "# Title\n\n1. first\n2. sec")
        XCTAssertEqual(blocks, [.markdown("# Title\n\n1. first\n2. sec")])
    }

    func testIncrementalAppendNeverThrowsAndKeepsAnOpenFence() {
        let tokens = [
            "Look:\n\n",
            "```",
            "swift\n",
            "let x = 1\n",
            "let y = ",
        ]
        var source = ""
        for token in tokens {
            source += token
            let blocks = StreamingMarkdown.blocks(from: source)
            XCTAssertFalse(blocks.isEmpty)
        }
        let last = StreamingMarkdown.blocks(from: source).last
        guard case .code(_, let text, false) = last else {
            return XCTFail("streaming fence should stay open")
        }
        XCTAssertTrue(text.contains("let x = 1"))
    }

    func testClosedPrefixIdentityStaysStableWhileTheTailGrows() {
        let prefix = "Before\n\n"
        let first = StreamingMarkdown.blocks(from: prefix)
        let withMoment = StreamingMarkdown.blocks(
            from: prefix + "![2:14 Safari](afterray://moment/moment-123)\n\nAfter"
        )
        XCTAssertEqual(first.first, withMoment.first)
        XCTAssertEqual(first.first, .markdown("Before"))
        XCTAssertEqual(
            withMoment,
            [
                .markdown("Before"),
                .momentImage(label: "2:14 Safari", momentID: "moment-123"),
                .markdown("After"),
            ]
        )
    }

    func testCloseDanglingBoldAndInlineCode() {
        XCTAssertEqual(StreamingMarkdown.closeDanglingInlineMarkup("hello **wo"), "hello **wo**")
        XCTAssertEqual(StreamingMarkdown.closeDanglingInlineMarkup("use `code"), "use `code`")
        XCTAssertEqual(StreamingMarkdown.closeDanglingInlineMarkup("*em"), "*em*")
    }

    func testIncompleteLinkIsStrippedInsteadOfBreakingParse() {
        let closed = StreamingMarkdown.closeDanglingInlineMarkup("see [docs](http")
        XCTAssertFalse(closed.contains("]("))
        _ = StreamingMarkdown.attributedInline("see [docs](http")
    }

    func testQuoteAndRuleStayInTheLibraryChunk() {
        let blocks = StreamingMarkdown.blocks(from: "> leftover light\n\n---")
        XCTAssertEqual(blocks, [.markdown("> leftover light\n\n---")])
    }

    func testStandaloneMomentImageBecomesTrustedMediaBlock() {
        let source = "Before\n\n![2:14 Safari](afterray://moment/moment-123)\n\nAfter"
        XCTAssertEqual(
            StreamingMarkdown.blocks(from: source),
            [
                .markdown("Before"),
                .momentImage(label: "2:14 Safari", momentID: "moment-123"),
                .markdown("After"),
            ]
        )
    }

    func testNumericMomentIDCitationBecomesPreviewCard() {
        let source = "![2:14 Safari](afterray://moment/1786936000000)"
        XCTAssertEqual(
            StreamingMarkdown.blocks(from: source),
            [.momentImage(label: "2:14 Safari", momentID: "1786936000000")]
        )
    }

    func testIndentedAndListPrefixedMomentImagesBecomeMedia() {
        XCTAssertEqual(
            StreamingMarkdown.blocks(from: "  ![2:14 Safari](afterray://moment/1786936000000)"),
            [.momentImage(label: "2:14 Safari", momentID: "1786936000000")]
        )
        XCTAssertEqual(
            StreamingMarkdown.blocks(from: "- ![2:14 Safari](afterray://moment/1786936000000)"),
            [.momentImage(label: "2:14 Safari", momentID: "1786936000000")]
        )
    }

    func testEmbeddedMomentImageBecomesMediaAndKeepsSurroundingProse() {
        XCTAssertEqual(
            StreamingMarkdown.blocks(from: "See ![frame](afterray://moment/abc) here"),
            [
                .markdown("See "),
                .momentImage(label: "frame", momentID: "abc"),
                .markdown(" here"),
            ]
        )
    }

    func testExternalAndLocalImagesStaySelectableText() {
        for source in [
            "![remote](https://example.com/image.jpg)",
            "![local](file:///tmp/private.png)",
            "![inline](data:image/png;base64,AAAA)",
        ] {
            let blocks = StreamingMarkdown.blocks(from: source)
            XCTAssertEqual(blocks.count, 1)
            guard case .markdown(let text) = blocks[0] else {
                return XCTFail("external image should stay a markdown text slice")
            }
            XCTAssertFalse(text.hasPrefix("!["), "unescaped image syntax would load media")
            XCTAssertTrue(text.contains("\\!\\["))
            XCTAssertEqual(blocks, [.markdown(StreamingMarkdown.escapeUntrustedImages(source))])
        }
    }

    func testEscapeUntrustedImagesLeavesTheOriginalCharactersSelectable() {
        let escaped = StreamingMarkdown.escapeUntrustedImages("![remote](https://example.com/a.png)")
        XCTAssertEqual(escaped, "\\!\\[remote](https://example.com/a.png)")
    }

    func testEscapeUntrustedImagesLeavesMomentCitationsIntact() {
        let source = "![2:14 Safari](afterray://moment/1786936000000)"
        XCTAssertEqual(StreamingMarkdown.escapeUntrustedImages(source), source)
    }

    func testPartialMomentImageDoesNotLoadMedia() {
        let partial = StreamingMarkdown.blocks(from: "![still streaming](afterray://moment/abc")
        XCTAssertEqual(partial.count, 1)
        guard case .markdown(let partialText) = partial[0] else {
            return XCTFail("incomplete moment image must not become media")
        }
        XCTAssertTrue(partialText.contains("afterray://moment/abc"))
        XCTAssertFalse(partial.contains { if case .momentImage = $0 { return true } else { return false } })
    }

    func testMomentURLParserAcceptsOnlyTheAfterrayScheme() {
        XCTAssertEqual(
            StreamingMarkdown.momentID(from: URL(string: "afterray://moment/moment-123")!),
            "moment-123"
        )
        XCTAssertNil(StreamingMarkdown.momentID(from: URL(string: "https://example.com/moment/abc")!))
        XCTAssertNil(StreamingMarkdown.momentID(from: URL(string: "file:///tmp/private.png")!))
        XCTAssertNil(StreamingMarkdown.momentID(from: URL(string: "afterray://other/moment-123")!))
    }

    func testIncompleteTableDoesNotPoisonLaterParagraphsOnceClosed() {
        var source = """
        | a | b
        """
        XCTAssertEqual(StreamingMarkdown.blocks(from: source).count, 1)
        source += """

        | --- | --- |
        | 1 | 2 |

        after
        """
        let blocks = StreamingMarkdown.blocks(from: source)
        XCTAssertEqual(blocks.count, 1)
        guard case .markdown(let text) = blocks[0] else {
            return XCTFail("closed table should stay in the library chunk")
        }
        XCTAssertTrue(text.contains("| 1 | 2 |"))
        XCTAssertTrue(text.contains("after"))
    }
}
