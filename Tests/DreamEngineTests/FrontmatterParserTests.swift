import XCTest
@testable import DreamEngine

final class FrontmatterParserTests: XCTestCase {

    func testEmpty_returnsEmpty() {
        let doc = FrontmatterParser().parse("")
        XCTAssertTrue(doc.isEmpty)
        XCTAssertEqual(doc.body, "")
        XCTAssertEqual(doc.bodyStartLine, 1)
    }

    func testNoFrontmatter_returnsBodyAsIs() {
        let text = "Hello world\nSecond line"
        let doc = FrontmatterParser().parse(text)
        XCTAssertTrue(doc.isEmpty)
        XCTAssertEqual(doc.body, text)
    }

    func testSimpleStringField() {
        let text = """
        ---
        title: Hello
        author: bio
        ---
        body
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["title"], .string("Hello"))
        XCTAssertEqual(doc.fields["author"], .string("bio"))
        XCTAssertEqual(doc.orderedKeys, ["title", "author"])
        XCTAssertEqual(doc.body, "body")
        // 行 1: `---`, 行 2: title, 行 3: author, 行 4: `---`, 行 5: body
        XCTAssertEqual(doc.bodyStartLine, 5)
    }

    func testNumberAndBool() {
        let text = """
        ---
        count: 42
        ratio: 3.14
        active: true
        archived: false
        nothing: null
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["count"], .number(42))
        XCTAssertEqual(doc.fields["ratio"], .number(3.14))
        XCTAssertEqual(doc.fields["active"], .bool(true))
        XCTAssertEqual(doc.fields["archived"], .bool(false))
        XCTAssertEqual(doc.fields["nothing"], .null)
    }

    func testStringList() {
        let text = """
        ---
        tags: [swift, markdown, dream]
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["tags"], .stringList(["swift", "markdown", "dream"]))
    }

    func testIntList() {
        let text = """
        ---
        scores: [10, 20, 30]
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["scores"], .intList([10, 20, 30]))
    }

    func testQuotedString() {
        let text = """
        ---
        title: "Hello: World"
        desc: 'with: colon'
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["title"], .string("Hello: World"))
        XCTAssertEqual(doc.fields["desc"], .string("with: colon"))
    }

    func testUnclosedFrontmatter_fallsBackToPlainText() {
        let text = "title: oops\nno closing fence"
        let doc = FrontmatterParser().parse(text)
        XCTAssertTrue(doc.isEmpty, "缺闭合应按无 frontmatter 处理")
        XCTAssertEqual(doc.body, text)
    }

    func testOrderedKeys_preserveInsertionOrder() {
        let text = """
        ---
        zebra: 1
        apple: 2
        mango: 3
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.orderedKeys, ["zebra", "apple", "mango"])
    }

    func testDuplicateKey_keepsFirst() {
        // 后出现的同名 key 不应覆盖前面的（保留第一次）
        let text = """
        ---
        name: first
        name: second
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["name"], .string("first"))
    }

    func testCommentLines_skipped() {
        let text = """
        ---
        # this is a comment
        title: real
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertNil(doc.fields["# this is a comment"])
        XCTAssertEqual(doc.fields["title"], .string("real"))
    }

    func testRoundTrip() {
        let text = """
        ---
        title: Round Trip
        count: 7
        tags: [a, b]
        ---
        body content
        """
        let doc = FrontmatterParser().parse(text)
        let rendered = FrontmatterParser.render(doc)
        // round-trip 后再 parse 应该一致
        let reparsed = FrontmatterParser().parse("---\n\(rendered)\n---\nbody content")
        XCTAssertEqual(reparsed.fields["title"], .string("Round Trip"))
        XCTAssertEqual(reparsed.fields["count"], .number(7))
        XCTAssertEqual(reparsed.fields["tags"], .stringList(["a", "b"]))
    }

    func testNestedObject() {
        let text = """
        ---
        source:
          file: raw/a.md
          line: 12
        ---
        """
        let doc = FrontmatterParser().parse(text)
        guard case .object(let inner) = doc.fields["source"] else {
            XCTFail("expected object")
            return
        }
        XCTAssertEqual(inner["file"], .string("raw/a.md"))
        XCTAssertEqual(inner["line"], .number(12))
    }

    func testEmptyValue_isString() {
        let text = """
        ---
        title:
        ---
        """
        let doc = FrontmatterParser().parse(text)
        XCTAssertEqual(doc.fields["title"], .string(""))
    }
}
