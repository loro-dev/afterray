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
        XCTAssertEqual(blocks[0], .paragraph("Before"))
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
        XCTAssertEqual(blocks[1], .paragraph("after"))
    }

    func testPartialListRendersCompletedItems() {
        let blocks = StreamingMarkdown.blocks(from: "- one\n- two\n- ")
        XCTAssertEqual(blocks, [.bulletedList(["one", "two", ""])])
    }

    func testNumberedListAndHeadingSurviveHalfwayThrough() {
        let blocks = StreamingMarkdown.blocks(from: "# Title\n\n1. first\n2. sec")
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .numberedList(["first", "sec"]))
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

    func testQuoteAndRule() {
        let blocks = StreamingMarkdown.blocks(from: "> leftover light\n\n---")
        XCTAssertEqual(blocks, [.quote("leftover light"), .rule])
    }
}
