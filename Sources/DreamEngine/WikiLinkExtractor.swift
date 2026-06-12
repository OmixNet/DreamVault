// P2-3: 扫文本找 [[xxx]] / [[xxx|alias]], 返 segments (NSAttributedString) 高亮蓝色下划线 + .link
import Foundation
import AppKit

/// P2-3: 扫到的 wikilink 段
public struct WikiLinkSegment: Equatable, Sendable {
    public let target: String     // 跳转目标 (e.g. "swiftui" 或 "raw/notes.md")
    public let label: String      // 显示文字 (alias 或 target)
    public let range: NSRange     // 在源文本里的位置
    public let linkURL: URL       // dreamvault://wikilink/<encoded target>
    public init(target: String, label: String, range: NSRange, linkURL: URL) {
        self.target = target
        self.label = label
        self.range = range
        self.linkURL = linkURL
    }
}

/// P2-3: 从 raw markdown 文本里抽出所有 [[wikilink]]
///
/// 支持:
///   - `[[target]]`           target == label == 名字
///   - `[[target|alias]]`     target 跳转, alias 显示
///   - `[[target]]` 内不允许换行 (单行)
///   - 嵌套 `[` 必须 escape (e.g. `[[a[b]]` 解析成 a[b)
public enum WikiLinkExtractor {
    /// 抽 segments + 拼接纯文本
    /// - Returns: (segments, plainText) — plainText = 源文本 (不变, 保留 markdown 字符)
    public static func extract(from source: String) -> [WikiLinkSegment] {
        var segments: [WikiLinkSegment] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            // 找 "[["
            guard chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" else {
                i += 1
                continue
            }
            // 找 "]]"
            let innerStart = i + 2
            var j = innerStart
            var foundClose = false
            while j < chars.count - 1 {
                if chars[j] == "]" && chars[j + 1] == "]" {
                    foundClose = true
                    break
                }
                if chars[j] == "\n" {
                    // 跨行不算 (单行 wikilink)
                    break
                }
                j += 1
            }
            if !foundClose {
                i += 1
                continue
            }
            // 解析 inner: target | alias
            let inner = String(chars[innerStart..<j])
            if inner.isEmpty {
                i += 1
                continue
            }
            let (target, label) = parseWikilinkTarget(inner)
            // 编码 target → URL
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            let urlStr = "dreamvault://wikilink/\(encoded)"
            guard let url = URL(string: urlStr) else { i += 1; continue }
            let range = NSRange(location: i, length: j + 2 - i)
            segments.append(WikiLinkSegment(target: target, label: label, range: range, linkURL: url))
            i = j + 2
        }
        return segments
    }

    /// 解析 "target|alias" → ("target", "alias"); 无 "|" → (inner, inner)
    public static func parseWikilinkTarget(_ inner: String) -> (target: String, label: String) {
        if let pipeIdx = inner.firstIndex(of: "|") {
            let target = String(inner[..<pipeIdx])
            let label = String(inner[inner.index(after: pipeIdx)...])
            return (target, label)
        }
        return (inner, inner)
    }

    /// P2-3: 装饰 NSAttributedString — 给 wikilink 段加蓝色 + 下划线 + .link attribute
    /// 保留源文本 (markdown 字符 [[ ]] 都还在)
    public static func attributedString(from source: String,
                                        baseAttrs: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: baseAttrs)
        let segments = extract(from: source)
        var attrs = baseAttrs
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        // Tooltip 暂时不挂 (NSAttributedString 不存 .toolTip 直接, 通过 NSView delegate)
        for seg in segments {
            // 只覆盖 label 范围 (不覆盖 [[ ]]), 这样 [[ 显示正常, alias 高亮
            // 简单做法: 全段高亮 (跟 MarkdownRenderer 一致)
            result.addAttributes(attrs, range: seg.range)
            result.addAttribute(.link, value: seg.linkURL, range: seg.range)
        }
        return result
    }

    /// P2-3: 给光标位置插入 [[target]], 自动 wrap, 把 `|` 放在 alias 位置
    /// - Returns: 插入的文本 + 新光标位置
    public static func insertionString(target: String, alias: String? = nil) -> String {
        if let a = alias, !a.isEmpty, a != target {
            return "[[\(target)|\(a)]]"
        }
        return "[[\(target)]]"
    }
}
