import AppKit

/// P1 修复 (缺陷报告 §3.3 P1.2): Markdown 语法高亮.
/// 给定 plain text 返 NSAttributedString 含 4 类高亮:
///   1. 标题 (# / ## / ###) - 粗体 + 颜色 (system blue)
///   2. 粗体 (**text**) - 粗体 (NSFont.boldSystemFont)
///   3. 行内代码 (`code`) - 等宽 + 背景色 (system gray)
///   4. Markdown 链接 ([text](url)) - 颜色 (system teal) + 下划线
///
/// 设计:
/// - 静态 helper, 不持有状态, 跟 WikiLinkExtractor.attributedString 同 pattern
/// - 走 NSRegularExpression (Foundation 自带, 跨平台)
/// - 应用在 WikiLinkExtractor 之后, 不破坏 wikilink 的 .link attribute
///   (wikilink 跟 markdown link 都是 [..](..) 但 wikilink 走 `dreamvault://wikilink/<id>` 协议)
///   优先级: wikilink 先判, 剩下的才走 markdown 链接匹配
public enum MarkdownHighlighter {

    /// 4 类高亮的颜色 (NSColor.systemColor 跟系统主题)
    public static let headingColor: NSColor = .systemBlue
    public static let boldColor: NSColor = .labelColor  // 跟默认前景色一致
    public static let codeColor: NSColor = .systemPink
    public static let codeBackgroundColor: NSColor = NSColor.systemGray.withAlphaComponent(0.18)
    public static let linkColor: NSColor = .systemTeal

    public static let baseFontSize: CGFloat = 13
    public static let headingFontSize: CGFloat = 16
    public static let codeFontSize: CGFloat = 12

    /// 把 plain markdown 文本转 NSMutableAttributedString, 叠加 4 类高亮.
    /// - baseAttrs: 基础属性 (字体/前景色, 由 NSTextView 提供)
    /// - wikilinkRanges: WikiLinkExtractor 已识别并标了 .link attribute 的范围 (跳过这些, 避免双重着色)
    /// - Returns: 完整 NSMutableAttributedString, 含 markdown 高亮 (mutable 是为了调用方还能加 .link 等)
    public static func highlighted(
        _ text: String,
        baseFont: NSFont,
        baseColor: NSColor = .labelColor,
        skipRanges: [NSRange] = []
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: baseColor,
        ])

        // 1) 标题: 行首的 # / ## / ### (到行尾)
        applyHeadingHighlight(to: result, baseFont: baseFont)

        // 2) 粗体: **text** (非贪婪)
        applyBoldHighlight(to: result, baseFont: baseFont)

        // 3) 行内代码: `code` (非贪婪)
        applyCodeHighlight(to: result)

        // 4) Markdown 链接: [text](url) — 跳过 wikilink 范围
        applyLinkHighlight(to: result, skipRanges: skipRanges)

        return result
    }

    // MARK: - 标题 (# / ## / ###)

    /// 标题: 行首 # / ## / ### (1-3 个 #, 跟空格), 到行尾或下一个空行.
    /// 简化: 不实现 4+ 级标题 (HTML/md 支持但 dreamvault 不需要).
    private static func applyHeadingHighlight(to attr: NSMutableAttributedString, baseFont: NSFont) {
        let pattern = #"(?m)^(#{1,3})\s+(.*?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = attr.string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: attr.string, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let hashesRange = m.range(at: 1)
            let contentRange = m.range(at: 2)
            // 粗体 + 蓝色 + 略大字号
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: headingFontSize),
                .foregroundColor: headingColor,
            ]
            attr.addAttributes(attrs, range: contentRange)
            // # 符号也着色
            attr.addAttribute(.foregroundColor, value: headingColor.withAlphaComponent(0.6), range: hashesRange)
        }
    }

    // MARK: - 粗体 (**text**)

    /// 粗体: **text** (非贪婪, 不跨行).
    /// 不支持跨段粗体 (e.g. 段落开头 **不闭合), 简化.
    private static func applyBoldHighlight(to attr: NSMutableAttributedString, baseFont: NSFont) {
        let pattern = #"\*\*([^\*\n]+?)\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = attr.string as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: attr.string, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let contentRange = m.range(at: 1)
            // 用 boldSystemFont (同 baseFont size) 替代 default
            attr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFontSize), range: contentRange)
        }
    }

    // MARK: - 行内代码 (`code`)

    /// 行内代码: `code` (非贪婪, 不跨行).
    private static func applyCodeHighlight(to attr: NSMutableAttributedString) {
        let pattern = #"`([^`\n]+?)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(location: 0, length: attr.length)
        regex.enumerateMatches(in: attr.string, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let contentRange = m.range(at: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
                .foregroundColor: codeColor,
                .backgroundColor: codeBackgroundColor,
            ]
            attr.addAttributes(attrs, range: contentRange)
        }
    }

    // MARK: - Markdown 链接 ([text](url))

    /// Markdown 链接: [text](url) (非贪婪).
    /// 跳过 wikilink 范围 (WikiLinkExtractor 已标 .link attribute), 避免双重着色.
    private static func applyLinkHighlight(to attr: NSMutableAttributedString, skipRanges: [NSRange]) {
        let pattern = #"\[([^\]\n]+?)\]\(([^\s\)]+?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(location: 0, length: attr.length)
        regex.enumerateMatches(in: attr.string, range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let textRange = m.range(at: 1)
            let urlRange = m.range(at: 2)
            let fullMatch = m.range
            // 跳过 wikilink 范围 (wikilink 已是 [text](url) 同 pattern)
            if skipRanges.contains(where: { NSIntersectionRange($0, fullMatch).length > 0 }) {
                return
            }
            // text 范围着色 (link 文字)
            attr.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: textRange)
            // url 范围浅色
            attr.addAttribute(.foregroundColor, value: linkColor.withAlphaComponent(0.7), range: urlRange)
        }
    }
}
