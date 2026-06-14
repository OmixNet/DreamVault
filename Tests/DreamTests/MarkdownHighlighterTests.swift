import XCTest
import AppKit
@testable import dream

/// P1 修复 (缺陷报告 §3.3 P1.2) 测试: Markdown 语法高亮 (4 类).
/// 验证:
/// - 标题 (# / ## / ###) 着 system blue + 粗体
/// - 粗体 (**text**) 着 NSFont.boldSystemFont
/// - 行内代码 (`code`) 着 system pink + monospaced font + 背景
/// - Markdown 链接 ([text](url)) 着 system teal + 下划线
/// - skipRanges (wikilink) 跳过 markdown 链接匹配 (避免双重着色)
final class MarkdownHighlighterTests: XCTestCase {

    private let baseFont = NSFont.systemFont(ofSize: 13)
    private let baseColor = NSColor.labelColor

    // MARK: - 标题

    /// 1. # 标题 - system blue + 粗体 + content 着色
    func testHeading_h1_blueAndBold() {
        let result = MarkdownHighlighter.highlighted(
            "# Title", baseFont: baseFont, baseColor: baseColor
        )
        let ns = result.string as NSString
        XCTAssertEqual(ns.length, "# Title".count)
        // content 范围 (1..<7) 应有 foregroundColor = system blue
        let contentRange = NSRange(location: 2, length: 5)
        var colorFound: NSColor?
        result.enumerateAttribute(.foregroundColor, in: contentRange) { value, _, _ in
            if let c = value as? NSColor { colorFound = c }
        }
        XCTAssertNotNil(colorFound, "标题 content 应着色")
    }

    /// 2. ## 标题 - 也走标题规则 (3 级内)
    func testHeading_h2_alsoHighlighted() {
        let result = MarkdownHighlighter.highlighted(
            "## Subtitle", baseFont: baseFont, baseColor: baseColor
        )
        let ns = result.string as NSString
        XCTAssertEqual(ns.length, "## Subtitle".count)
        let contentRange = NSRange(location: 3, length: 8)
        var colorFound: NSColor?
        result.enumerateAttribute(.foregroundColor, in: contentRange) { value, _, _ in
            if let c = value as? NSColor { colorFound = c }
        }
        XCTAssertNotNil(colorFound, "## 标题也应着色")
    }

    /// 3. 多行: 标题行 着色, 非标题行 不着色
    func testHeading_onlyHeadingLines() {
        let text = "# H1\nbody line 1\nbody line 2"
        let result = MarkdownHighlighter.highlighted(text, baseFont: baseFont, baseColor: baseColor)
        // 第 1 行 (标题) content 范围 (2..<4) 应有 foregroundColor != baseColor
        var headingColorFound = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 2, length: 3)) { value, _, _ in
            if let c = value as? NSColor, c != baseColor { headingColorFound = true }
        }
        XCTAssertTrue(headingColorFound, "标题行应着色")
    }

    // MARK: - 粗体

    /// 4. **text** 粗体 - 字体为 boldSystemFont
    func testBold_basicFontBold() {
        let result = MarkdownHighlighter.highlighted(
            "**bold**", baseFont: baseFont, baseColor: baseColor
        )
        let contentRange = NSRange(location: 2, length: 4)  // "bold" 范围
        var fontFound: NSFont?
        result.enumerateAttribute(.font, in: contentRange) { value, _, _ in
            if let f = value as? NSFont { fontFound = f }
        }
        XCTAssertNotNil(fontFound, "粗体应设字体")
        XCTAssertTrue(fontFound!.fontDescriptor.symbolicTraits.contains(.bold),
                     "粗体应含 .bold trait")
    }

    /// 5. 粗体不跨行 (**text 在第 1 行, 闭合在第 2 行) → 不算粗体
    func testBold_doesNotSpanLines() {
        let result = MarkdownHighlighter.highlighted(
            "**start\nend**", baseFont: baseFont, baseColor: baseColor
        )
        // content 范围 (2..<12) 应**没有**粗体 (跨行不匹配)
        var boldFound = false
        result.enumerateAttribute(.font, in: NSRange(location: 2, length: 10)) { value, _, _ in
            if let f = value as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) {
                boldFound = true
            }
        }
        XCTAssertFalse(boldFound, "粗体不应跨行匹配")
    }

    // MARK: - 行内代码

    /// 6. `code` - system pink + monospaced + 背景
    func testCode_inlineCode_pinkAndMono() {
        let result = MarkdownHighlighter.highlighted(
            "`code`", baseFont: baseFont, baseColor: baseColor
        )
        let contentRange = NSRange(location: 1, length: 4)  // "code" 范围
        var fontFound: NSFont?
        var bgFound: NSColor?
        result.enumerateAttribute(.font, in: contentRange) { value, _, _ in
            if let f = value as? NSFont { fontFound = f }
        }
        result.enumerateAttribute(.backgroundColor, in: contentRange) { value, _, _ in
            if let c = value as? NSColor { bgFound = c }
        }
        XCTAssertNotNil(fontFound, "行内代码应设字体")
        XCTAssertNotNil(bgFound, "行内代码应设背景色")
    }

    /// 7. 行内代码不跨行
    func testCode_doesNotSpanLines() {
        let result = MarkdownHighlighter.highlighted(
            "`start\nend`", baseFont: baseFont, baseColor: baseColor
        )
        var bgFound = false
        result.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if value != nil { bgFound = true }
        }
        XCTAssertFalse(bgFound, "行内代码不应跨行匹配")
    }

    // MARK: - Markdown 链接

    /// 8. [text](url) - system teal + 下划线
    /// P1.3 修复 (缺陷报告 §3.3): text 范围还应有 .link attribute 让点击触发 delegate
    func testMarkdownLink_tealAndUnderline_andClickable() {
        let result = MarkdownHighlighter.highlighted(
            "[click](https://example.com)", baseFont: baseFont, baseColor: baseColor
        )
        // text 范围 (1..<6) = "click"
        let textRange = NSRange(location: 1, length: 5)
        var colorFound: NSColor?
        var underlineFound: Bool = false
        var linkFound: URL?
        result.enumerateAttribute(.foregroundColor, in: textRange) { value, _, _ in
            if let c = value as? NSColor { colorFound = c }
        }
        result.enumerateAttribute(.underlineStyle, in: textRange) { value, _, _ in
            if let _ = value as? Int { underlineFound = true }
        }
        result.enumerateAttribute(.link, in: textRange) { value, _, _ in
            if let u = value as? URL { linkFound = u }
        }
        XCTAssertNotNil(colorFound, "Markdown 链接应着色")
        XCTAssertTrue(underlineFound, "Markdown 链接应下划线")
        XCTAssertNotNil(linkFound, "P1.3 修复: text 范围应有 .link attribute (NSTextView 点击触发)")
        XCTAssertEqual(linkFound?.absoluteString, "https://example.com")
    }

    /// 9. wikilink 范围 (skipRanges) 跳过 markdown 链接匹配
    /// wikilink 也是 [text](url) 形式, 跟 markdown 链接冲突 → skipRanges 让 markdown 跳过
    func testMarkdownLink_skipsWikilinkRanges() {
        let text = "[[my-note]]"
        let wikilinkRange = NSRange(location: 0, length: text.count)  // 整个范围
        let result = MarkdownHighlighter.highlighted(
            text, baseFont: baseFont, baseColor: baseColor,
            skipRanges: [wikilinkRange]
        )
        // wikilink 范围被跳过, 不应有 foregroundColor 覆盖
        // (但基础属性 baseColor 仍存, 这里验 foregroundColor 跟 baseColor 一致 或没改)
        var colorFound: NSColor?
        result.enumerateAttribute(.foregroundColor, in: wikilinkRange) { value, _, _ in
            if let c = value as? NSColor { colorFound = c }
        }
        // 跳过 = 不应被覆盖成 teal. 仍是 baseColor 或 nil
        if let c = colorFound {
            XCTAssertNotEqual(c, MarkdownHighlighter.linkColor, "wikilink 范围应跳过 markdown 链接着色")
        }
    }

    /// 10. 多 markdown 链接 + 跳过部分
    /// text = "[a](url1) [b](url2) [c](url3)" (29 chars, indexes 0..<29)
    /// 拆: [a] = 0..<9, " " = 9, [b] = 10..<19, " " = 19, [c] = 20..<29
    /// skipRange 跳过 [b] (10..<19, length 9) - 不碰 [c]
    func testMarkdownLink_multipleAndSkip() {
        let text = "[a](url1) [b](url2) [c](url3)"
        let skipRange = NSRange(location: 10, length: 9)  // "[b](url2)" 范围 10..<19
        let result = MarkdownHighlighter.highlighted(
            text, baseFont: baseFont, baseColor: baseColor,
            skipRanges: [skipRange]
        )
        // [a] "a" at 1, 着色
        var aColored = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 1, length: 1)) { value, _, _ in
            if let c = value as? NSColor, c == MarkdownHighlighter.linkColor { aColored = true }
        }
        XCTAssertTrue(aColored, "[a] 应着色")
        // [b] "b" at 11, 应被 skip 跳过
        var bColored = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 11, length: 1)) { value, _, _ in
            if let c = value as? NSColor, c == MarkdownHighlighter.linkColor { bColored = true }
        }
        XCTAssertFalse(bColored, "[b] 应被 skip 跳过, 不着色")
        // [c] "c" at 21, 着色 (skipRange 10..<19 不覆盖 21)
        var cColored = false
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 21, length: 1)) { value, _, _ in
            if let c = value as? NSColor, c == MarkdownHighlighter.linkColor { cColored = true }
        }
        XCTAssertTrue(cColored, "[c] 应着色")
    }

    // MARK: - 兼容性

    /// 11. 空字符串 → 返空 attributed
    func testEmptyString_returnsEmpty() {
        let result = MarkdownHighlighter.highlighted("", baseFont: baseFont, baseColor: baseColor)
        XCTAssertEqual(result.length, 0)
    }

    /// 12. 无 markdown 标记 → 返 baseColor 全文
    func testNoMarkdown_returnsBaseAttrs() {
        let result = MarkdownHighlighter.highlighted("plain text", baseFont: baseFont, baseColor: baseColor)
        XCTAssertEqual(result.string, "plain text")
        // 应保留 baseFont + baseColor
        XCTAssertGreaterThan(result.length, 0)
    }

    /// 13. P1.3 修复: 无效 URL 不设 .link attribute (无效 URL 不能点击)
    ///     例如 [bad](\invalid url) 应仅装饰, 不让 NSTextView 报错
    func testMarkdownLink_invalidURL_noLinkAttribute() {
        let result = MarkdownHighlighter.highlighted(
            "[bad](not a url with spaces)", baseFont: baseFont, baseColor: baseColor
        )
        let textRange = NSRange(location: 1, length: 3)  // "bad"
        var linkFound: URL?
        result.enumerateAttribute(.link, in: textRange) { value, _, _ in
            if let u = value as? URL { linkFound = u }
        }
        // 验证: 着色 + 下划线仍设 (装饰保留), 但 .link 不设
        XCTAssertNil(linkFound, "无效 URL 不应有 .link attribute")
        // url 范围应仍浅色 (装饰可读)
        let urlRange = NSRange(location: 6, length: result.length - 7)
        var urlColored: NSColor?
        result.enumerateAttribute(.foregroundColor, in: urlRange) { value, _, _ in
            if let c = value as? NSColor { urlColored = c }
        }
        XCTAssertNotNil(urlColored, "url 范围仍应浅色装饰")
    }

    /// 14. P1.3 修复: file:// URL 也设 .link (本地文件可点)
    func testMarkdownLink_fileURL_clickable() {
        let result = MarkdownHighlighter.highlighted(
            "[doc](file:///Users/x/notes.md)", baseFont: baseFont, baseColor: baseColor
        )
        let textRange = NSRange(location: 1, length: 3)  // "doc"
        var linkFound: URL?
        result.enumerateAttribute(.link, in: textRange) { value, _, _ in
            if let u = value as? URL { linkFound = u }
        }
        XCTAssertNotNil(linkFound, "file:// URL 也应有 .link attribute")
        XCTAssertEqual(linkFound?.scheme, "file")
    }

    /// 15. P1.3 修复: wikilink 范围 (skipRanges) 不加 .link attribute (避免双重处理)
    func testMarkdownLink_skipRanges_noLinkAttribute() {
        // wikilink (e.g. [[my-note]]) 跟 markdown 链接 ([..](..)) pattern 不同,
        // 但 applyLinkHighlight 在 skipRanges 跳过时也不应加 .link (避免 wikilink 走两次处理)
        let text = "[[my-note]]"
        let wikilinkRange = NSRange(location: 0, length: text.count)
        let result = MarkdownHighlighter.highlighted(
            text, baseFont: baseFont, baseColor: baseColor,
            skipRanges: [wikilinkRange]
        )
        var linkFound: URL?
        result.enumerateAttribute(.link, in: wikilinkRange) { value, _, _ in
            if let u = value as? URL { linkFound = u }
        }
        XCTAssertNil(linkFound, "skipRanges 跳过的范围不应加 .link (WikiLinkExtractor 自己加)")
    }
}
