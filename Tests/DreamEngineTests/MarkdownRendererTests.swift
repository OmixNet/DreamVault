import XCTest
import AppKit
@testable import DreamEngine

final class MarkdownRendererTests: XCTestCase {

    let renderer = MarkdownRenderer()

    func testEmpty_returnsEmpty() {
        let s = renderer.render("")
        XCTAssertEqual(s.string, "")
    }

    func testPlainText() {
        let s = renderer.render("Hello world")
        XCTAssertTrue(s.string.contains("Hello world"))
    }

    func testH1H2H3() {
        let md = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        body
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("Heading 1"))
        XCTAssertTrue(s.string.contains("Heading 2"))
        XCTAssertTrue(s.string.contains("Heading 3"))
    }

    func testBoldAndItalic() {
        let md = "**bold** and *italic* and ***both***"
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("bold"))
        XCTAssertTrue(s.string.contains("italic"))
        XCTAssertTrue(s.string.contains("both"))
    }

    func testInlineCode() {
        let md = "Use `let foo = 1` to declare"
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("let foo = 1"))
    }

    func testFencedCodeBlock() {
        let md = """
        ```
        let x = 1
        let y = 2
        ```
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("let x = 1"))
        XCTAssertTrue(s.string.contains("let y = 2"))
    }

    func testFencedCodeBlockWithLanguage() {
        let md = """
        ```swift
        let x = 1
        ```
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("swift"))
        XCTAssertTrue(s.string.contains("let x = 1"))
    }

    func testQuote() {
        let md = "> This is a quote"
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("This is a quote"))
    }

    func testList() {
        let md = """
        - one
        - two
        - three
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("one"))
        XCTAssertTrue(s.string.contains("two"))
        XCTAssertTrue(s.string.contains("three"))
        XCTAssertTrue(s.string.contains("•"))  // bullet
    }

    func testHorizontalRule() {
        let md = """
        above
        ---
        below
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("above"))
        XCTAssertTrue(s.string.contains("below"))
    }

    func testWikilink_simple() {
        let md = "See [[other-page]] for details"
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("other-page"))
    }

    func testWikilink_withAlias() {
        let md = "See [[target-id|display text]] for details"
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("display text"))
        // 找含 "display text" 的子串，检查其 attribute 有 .link
        let nsString = s.string as NSString
        let range = nsString.range(of: "display text")
        XCTAssertNotEqual(range.location, NSNotFound)
        let attr = s.attributes(at: range.location, effectiveRange: nil)
        XCTAssertNotNil(attr[.link], "wikilink label 应含 .link attribute")
    }

    func testParagraph_preservesNewlines() {
        let md = """
        First line
        second line
        """
        let s = renderer.render(md)
        XCTAssertTrue(s.string.contains("First line"))
        XCTAssertTrue(s.string.contains("second line"))
    }
}
