import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 极简 Markdown 渲染器（.md → NSAttributedString）。
///
/// 支持的子集（够 95% 笔记 + 编辑器实时预览用）：
///   - `# H1` ... `###### H6`
///   - `**bold**` / `*italic*` / `***both***` / `` `code` ``
///   - `[text](url)` 链接（保留 attribute）
///   - `[[wikilink]]` / `[[wikilink|alias]]` 链接（NSColor.linkColor + .link URL）
///   - ` ``` fenced code blocks ``` `
///   - 引用 `> quote`
///   - 无序列表 `- item` / `* item`
///   - 水平线 `---` / `***`
///
/// 不支持（**显式不实现**）：
///   - 表格（复杂度高；Obsidian 也用插件做）
///   - 图片（vault 内相对路径解析复杂；留给后面）
///   - HTML 内嵌
public struct MarkdownRenderer {

    public init() {}

    /// 主入口：纯 markdown 文本 → NSAttributedString
    public func render(_ markdown: String, baseFontSize: CGFloat = 14) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        for block in parseBlocks(markdown) {
            result.append(renderBlock(block, baseFontSize: baseFontSize, baseAttrs: baseAttrs))
        }
        return result
    }

    // MARK: - 块解析

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case codeBlock(language: String?, code: String)
        case quote(text: String)
        case listItem(text: String)
        case horizontalRule
        case blank
        case table(rows: [[String]])        // P3-C2: 第一行 header，后续 body
        case image(alt: String, src: String)  // P3-C2: ![alt](src)
    }

    func parseBlocks(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                          code: codeLines.joined(separator: "\n")))
                if i < lines.count { i += 1 }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }
            if let (level, text) = parseHeading(line) {
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }
            if line.hasPrefix("> ") {
                blocks.append(.quote(text: String(line.dropFirst(2))))
                i += 1
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.listItem(text: String(line.dropFirst(2))))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                blocks.append(.blank)
                i += 1
                continue
            }
            // P3-C2: 图片单行 ![alt](src)
            if let (alt, src) = parseImageLine(trimmed) {
                blocks.append(.image(alt: alt, src: src))
                i += 1
                continue
            }
            // P3-C2: 表格多行 |col|col| + |---|---| 至少 2 行
            if trimmed.hasPrefix("|") && i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if isTableSeparator(next) {
                    var rows: [[String]] = [parseTableRow(trimmed)]
                    var j = i + 2
                    while j < lines.count {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        if !t.hasPrefix("|") { break }
                        rows.append(parseTableRow(t))
                        j += 1
                    }
                    blocks.append(.table(rows: rows))
                    i = j
                    continue
                }
            }
            // 段落
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if next.hasPrefix("#") || next.hasPrefix("```") ||
                   next.hasPrefix("> ") || next.hasPrefix("- ") || next.hasPrefix("* ") ||
                   nextTrimmed == "---" || nextTrimmed == "***" { break }
                paraLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
        }
        return blocks
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for c in line {
            if c == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    // MARK: - P3-C2: 表格 / 图片解析

    /// `![alt text](path/to/img.png)` 一行
    private func parseImageLine(_ line: String) -> (String, String)? {
        guard line.hasPrefix("![") else { return nil }
        guard let closeBracket = line.firstIndex(of: "]"),
              line[closeBracket...].hasPrefix("]("),
              let closeParen = line[closeBracket...].firstIndex(of: ")") else { return nil }
        let alt = String(line[line.index(after: line.startIndex)..<closeBracket])
        let afterBracket = line.index(after: closeBracket)
        let src = String(line[line.index(after: afterBracket)..<closeParen])
        guard !src.isEmpty else { return nil }
        return (alt, src)
    }

    /// `|---|---|` 风格的列分隔行
    private func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            // 每个 cell 形如 `---` / `:---` / `---:` / `:---:`
            return !trimmed.isEmpty &&
                trimmed.allSatisfy { $0 == "-" || $0 == ":" } &&
                trimmed.filter { $0 == "-" }.count >= 1
        }
    }

    /// `| a | b | c |` → `["a", "b", "c"]`
    private func parseTableRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 块渲染

    private func renderBlock(_ block: Block, baseFontSize: CGFloat,
                             baseAttrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [0, baseFontSize * 2.0, baseFontSize * 1.6, baseFontSize * 1.3,
                                    baseFontSize * 1.15, baseFontSize * 1.05, baseFontSize]
            let size = sizes[level]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            return renderInline(text, baseFontSize: size, baseAttrs: attrs)

        case .paragraph(let text):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
            return renderInline(text, baseFontSize: baseFontSize, baseAttrs: attrs)

        case .codeBlock(let language, let code):
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.92, weight: .regular),
                .foregroundColor: NSColor(white: 0.2, alpha: 1),
                .backgroundColor: NSColor(white: 0.94, alpha: 1),
            ]
            let result = NSMutableAttributedString()
            if let lang = language, !lang.isEmpty {
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.85, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                result.append(NSAttributedString(string: "```\(lang)\n", attributes: headerAttrs))
            }
            result.append(NSAttributedString(string: code, attributes: bodyAttrs))
            return result

        case .quote(let text):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor(white: 0.96, alpha: 1),
            ]
            let rendered = renderInline(text, baseFontSize: baseFontSize, baseAttrs: attrs)
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: "│  ", attributes: attrs))
            result.append(rendered)
            return result

        case .listItem(let text):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
            let rendered = renderInline(text, baseFontSize: baseFontSize, baseAttrs: attrs)
            let result = NSMutableAttributedString()
            result.append(NSAttributedString(string: "•  ", attributes: attrs))
            result.append(rendered)
            return result

        case .horizontalRule:
            return NSAttributedString(
                string: "────────────────",
                attributes: [
                    .font: NSFont.systemFont(ofSize: baseFontSize * 0.8),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )

        case .blank:
            return NSAttributedString(string: "")
        case .table(let rows):
            // 简化为 monospace 文本：每列对齐，header 加粗
            let colCount = rows.map { $0.count }.max() ?? 0
            guard colCount > 0 else { return NSAttributedString(string: "") }
            let widths = (0..<colCount).map { col -> Int in
                rows.map { row in
                    let idx = col < row.count ? col : 0
                    return row[idx].count
                }.max() ?? 8
            }
            let out = NSMutableAttributedString()
            for (ri, row) in rows.enumerated() {
                var line = ""
                for ci in 0..<colCount {
                    let cell = ci < row.count ? row[ci] : ""
                    let padded = cell.padding(toLength: widths[ci], withPad: " ", startingAt: 0)
                    line += "| " + padded + " "
                }
                line += "|"
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                if ri == 0 {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .bold)
                    attrs[.foregroundColor] = NSColor.labelColor
                }
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                if ri == 0 {
                    let sep = (0..<colCount).map { ci in
                        String(repeating: "-", count: widths[ci] + 2)
                    }.joined(separator: "+")
                    let sepLine = "+" + sep + "+\n"
                    out.append(NSAttributedString(string: sepLine, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular),
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]))
                }
            }
            return out
        case .image(let alt, let src):
            // 解析相对路径 → vault 内的图。当前 renderer 不持有 vaultRoot，
            // 走 cwd (process 启动目录) 兜底。EditorPane 用法在 vault 内打开文件时
            // cwd 一般就是 vault root，所以能命中。
            if let img = loadImage(relativePath: src) {
                let attachment = NSTextAttachment()
                attachment.image = img
                let result = NSMutableAttributedString(attachment: attachment)
                result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
                if !alt.isEmpty {
                    result.append(NSAttributedString(string: "[\(alt)]\n", attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: baseFontSize * 0.85)
                    ]))
                }
                return result
            }
            // 加载失败 → 占位符
            let failText = "[🖼 \(src) — \(alt.isEmpty ? "image" : alt)]\n"
            return NSAttributedString(string: failText, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: baseFontSize)
            ])
        }
    }

    /// 加载图片：先当绝对路径，失败再当相对 cwd 路径。
    private func loadImage(relativePath path: String) -> NSImage? {
        if let img = NSImage(contentsOfFile: path) { return img }
        let cwd = FileManager.default.currentDirectoryPath
        let rel = (path as NSString).expandingTildeInPath
        if let img = NSImage(contentsOfFile: rel) { return img }
        if let img = NSImage(contentsOfFile: cwd + "/" + path) { return img }
        return nil
    }

    // MARK: - 行内解析

    /// 解析行内 markup（**bold** *italic* `code` [[wikilink]]）。
    /// 不用 `+` 拼接 NSAttributedString，避免歧义；用 NSMutableAttributedString.append。
    func renderInline(_ text: String, baseFontSize: CGFloat,
                      baseAttrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            // 尝试匹配行内 token
            if let (attrStr, consumed) = matchInlineToken(
                chars: chars, start: i, baseFontSize: baseFontSize, baseAttrs: baseAttrs
            ) {
                result.append(attrStr)
                i += consumed
                continue
            }
            // 普通字符
            result.append(NSAttributedString(string: String(chars[i]), attributes: baseAttrs))
            i += 1
        }
        return result
    }

    /// 从 chars[start] 开始尝试匹配一个 inline token。
    /// 返回 (渲染结果, 消费字符数)。
    private func matchInlineToken(chars: [Character], start: Int, baseFontSize: CGFloat,
                                  baseAttrs: [NSAttributedString.Key: Any])
        -> (NSAttributedString, Int)? {
        guard start < chars.count else { return nil }
        let c0 = chars[start]
        // ***bold-italic***
        if c0 == "*" && start + 2 < chars.count &&
           chars[start + 1] == "*" && chars[start + 2] == "*" {
            if let end = findMarker("***", in: chars, from: start + 3) {
                let inner = String(chars[start + 3..<end])
                var attrs = baseAttrs
                attrs[.font] = NSFontManager.shared.convert(
                    (baseAttrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: baseFontSize),
                    toHaveTrait: [.boldFontMask, .italicFontMask]
                )
                let rendered = renderInline(inner, baseFontSize: baseFontSize, baseAttrs: attrs)
                return (rendered, end + 3 - start)
            }
            return nil
        }
        // **bold**
        if c0 == "*" && start + 1 < chars.count && chars[start + 1] == "*" {
            if let end = findMarker("**", in: chars, from: start + 2) {
                let inner = String(chars[start + 2..<end])
                var attrs = baseAttrs
                attrs[.font] = NSFontManager.shared.convert(
                    (baseAttrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: baseFontSize),
                    toHaveTrait: .boldFontMask
                )
                let rendered = renderInline(inner, baseFontSize: baseFontSize, baseAttrs: attrs)
                return (rendered, end + 2 - start)
            }
            return nil
        }
        // *italic*（单星号不接字母边界，避免误伤 "2*3" 这种算式；简化：只匹配前后是非字母）
        if c0 == "*" {
            if start + 1 < chars.count, let end = findMarker("*", in: chars, from: start + 1),
               end > start + 1 {
                let inner = String(chars[start + 1..<end])
                var attrs = baseAttrs
                attrs[.font] = NSFontManager.shared.convert(
                    (baseAttrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: baseFontSize),
                    toHaveTrait: .italicFontMask
                )
                let rendered = renderInline(inner, baseFontSize: baseFontSize, baseAttrs: attrs)
                return (rendered, end + 1 - start)
            }
            return nil
        }
        // `code`
        if c0 == "`" {
            if start + 1 < chars.count, let end = findMarker("`", in: chars, from: start + 1),
               end > start + 1 {
                let inner = String(chars[start + 1..<end])
                var attrs = baseAttrs
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.92, weight: .regular)
                attrs[.backgroundColor] = NSColor(white: 0.94, alpha: 1)
                return (NSAttributedString(string: inner, attributes: attrs), end + 1 - start)
            }
            return nil
        }
        // [[wikilink]] 或 [[wikilink|alias]]
        if c0 == "[", start + 1 < chars.count, chars[start + 1] == "[" {
            if let closeRel = findMarker("]]", in: chars, from: start + 2) {
                let inner = String(chars[start + 2..<closeRel])
                if !inner.isEmpty, !inner.contains("\n") {
                    let (target, label) = parseWikilinkTarget(inner)
                    var attrs = baseAttrs
                    let urlString = "dreamvault://wikilink/\(target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)"
                    if let url = URL(string: urlString) {
                        attrs[.link] = url
                    }
                    attrs[.foregroundColor] = NSColor.linkColor
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    return (NSAttributedString(string: label, attributes: attrs), closeRel + 2 - start)
                }
            }
            return nil
        }
        return nil
    }

    /// 在 chars[from..<count] 里找 marker 字符串（长度 ≥1）。返回 marker 起点的字符下标。
    private func findMarker(_ marker: String, in chars: [Character], from: Int) -> Int? {
        let m = Array(marker)
        guard !m.isEmpty else { return nil }
        var i = from
        while i + m.count <= chars.count {
            if chars[i..<(i + m.count)] == ArraySlice(m) { return i }
            i += 1
        }
        return nil
    }

    private func parseWikilinkTarget(_ inner: String) -> (target: String, label: String) {
        if let pipeRange = inner.range(of: "|") {
            return (String(inner[..<pipeRange.lowerBound]),
                    String(inner[pipeRange.upperBound...]))
        }
        return (inner, inner)
    }
}
