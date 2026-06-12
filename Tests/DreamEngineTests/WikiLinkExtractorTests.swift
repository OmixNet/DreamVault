// P2-3: WikiLinkExtractor 单测 + 跳转逻辑
import XCTest
@testable import DreamEngine
import AppKit

final class WikiLinkExtractorTests: XCTestCase {
    // MARK: - extract

    func testNoLinks() {
        let result = WikiLinkExtractor.extract(from: "hello world")
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleLink() {
        let result = WikiLinkExtractor.extract(from: "see [[swiftui]] for more")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "swiftui")
        XCTAssertEqual(result[0].label, "swiftui")
        XCTAssertEqual(result[0].range.location, 4)
        XCTAssertEqual(result[0].range.length, 11)  // [[swiftui]] = 11 chars
    }

    func testLinkWithAlias() {
        let result = WikiLinkExtractor.extract(from: "see [[swiftui|SwiftUI 笔记]] for more")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "swiftui")
        XCTAssertEqual(result[0].label, "SwiftUI 笔记")
    }

    func testMultipleLinks() {
        let result = WikiLinkExtractor.extract(from: "[[a]] and [[b]] and [[c|d]]")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].target, "a")
        XCTAssertEqual(result[1].target, "b")
        XCTAssertEqual(result[2].target, "c")
        XCTAssertEqual(result[2].label, "d")
    }

    func testLinkWithPath() {
        let result = WikiLinkExtractor.extract(from: "see [[raw/notes.md]] here")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "raw/notes.md")
    }

    func testLinkWithSpacesInAlias() {
        let result = WikiLinkExtractor.extract(from: "[[swiftui|Apple 的 SwiftUI]]")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "swiftui")
        XCTAssertEqual(result[0].label, "Apple 的 SwiftUI")
    }

    func testUnclosedLinkIgnored() {
        let result = WikiLinkExtractor.extract(from: "[[swiftui without close")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyLinkIgnored() {
        let result = WikiLinkExtractor.extract(from: "[[]] is nothing")
        XCTAssertTrue(result.isEmpty)
    }

    func testCrossNewlineLinkIgnored() {
        // 单行 wikilink, 跨行不算
        let result = WikiLinkExtractor.extract(from: "[[swiftui\nnext line]]")
        XCTAssertTrue(result.isEmpty)
    }

    func testLinkURL() {
        let result = WikiLinkExtractor.extract(from: "see [[swiftui]]")
        XCTAssertEqual(result[0].linkURL.scheme, "dreamvault")
        // url host/path 应含 swiftui
        let path = result[0].linkURL.path
        XCTAssertTrue(path.contains("swiftui"), "path 应含 swiftui; 实际: \(path)")
    }

    func testLinkWithURLSpecialChars() {
        // 含空格 / 中文 / 特殊字符
        let result = WikiLinkExtractor.extract(from: "[[raw/中文 笔记.md]]")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "raw/中文 笔记.md")
        // url 应是合法 (encoded)
        XCTAssertNotNil(result[0].linkURL)
    }

    func testBracketsNotMistakenForLinks() {
        // 单 [ 不是 link
        let result = WikiLinkExtractor.extract(from: "[a] and [b] and [[c]]")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].target, "c")
    }

    // MARK: - parseWikilinkTarget

    func testParseTargetNoAlias() {
        let (t, l) = WikiLinkExtractor.parseWikilinkTarget("swiftui")
        XCTAssertEqual(t, "swiftui")
        XCTAssertEqual(l, "swiftui")
    }

    func testParseTargetWithAlias() {
        let (t, l) = WikiLinkExtractor.parseWikilinkTarget("swiftui|SwiftUI 笔记")
        XCTAssertEqual(t, "swiftui")
        XCTAssertEqual(l, "SwiftUI 笔记")
    }

    func testParseTargetWithPipeInMiddle() {
        let (t, l) = WikiLinkExtractor.parseWikilinkTarget("a|b|c")
        // firstIndex 拿第一个 |
        XCTAssertEqual(t, "a")
        XCTAssertEqual(l, "b|c")
    }

    // MARK: - insertionString

    func testInsertionNoAlias() {
        XCTAssertEqual(WikiLinkExtractor.insertionString(target: "swiftui"), "[[swiftui]]")
    }

    func testInsertionWithAlias() {
        XCTAssertEqual(WikiLinkExtractor.insertionString(target: "swiftui", alias: "SwiftUI 笔记"),
                       "[[swiftui|SwiftUI 笔记]]")
    }

    func testInsertionEmptyAliasUsesTarget() {
        XCTAssertEqual(WikiLinkExtractor.insertionString(target: "swiftui", alias: ""), "[[swiftui]]")
    }

    func testInsertionAliasEqualsTarget() {
        XCTAssertEqual(WikiLinkExtractor.insertionString(target: "swiftui", alias: "swiftui"),
                       "[[swiftui]]")
    }

    // MARK: - attributedString

    func testAttributedStringHighlightsLinks() {
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let result = WikiLinkExtractor.attributedString(from: "see [[swiftui]] here",
                                                        baseAttrs: baseAttrs)
        XCTAssertEqual(result.string, "see [[swiftui]] here")
        // 整段 wikilink 应该有 .link attribute
        let link = result.attribute(.link, at: 4 + 1, effectiveRange: nil)  // [[swiftui]] 中间
        XCTAssertNotNil(link, "wikilink 段应有 .link attribute")
    }

    func testAttributedStringPreservesBaseAttrs() {
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let result = WikiLinkExtractor.attributedString(from: "plain [[swiftui]] text",
                                                        baseAttrs: baseAttrs)
        // 普通字符应保留 base font
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
    }

    func testAttributedStringColor() {
        let result = WikiLinkExtractor.attributedString(from: "[[x]]")
        let color = result.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(color, "wikilink 段应有 foregroundColor")
    }
}
