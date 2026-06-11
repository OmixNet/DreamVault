import Foundation

/// 文件命名 / 显示标题 规则（arch doc 不强制 schema，但需要稳定可预测）。
///
/// 规则：
///   - **raw/** 下的文件：永远不改文件名（arch doc 0.1 raw 永远只读、不参与重命名）
///   - **wiki/{entities,concepts,syntheses}/{memory-id}.md**：文件名 = memory id（稳定）
///   - **MEMORY.md** / 顶层普通 .md：filename 稳定；显示标题优先取 frontmatter.title，
///     fallback 到 H1（`# xxx`），再 fallback 到去掉 .md 的文件名
///
/// 设计：纯函数 + 显式枚举（不进 OOP），不依赖 filesystem。
public struct TitleResolver {

    public enum FileKind: Equatable, Sendable {
        case raw             // /raw/... → 永远不动文件名，不解析 frontmatter title
        case wikiMemory      // /wiki/{entities,concepts,syntheses}/{id}.md → 名字 = id
        case memoryMd        // /MEMORY.md → 顶层固定
        case plainNote       // 其他 .md → 自由命名
    }

    /// 根据相对路径判定文件类型
    public static func classify(relPath: String) -> FileKind {
        if relPath.hasPrefix("raw/") { return .raw }
        if relPath == "MEMORY.md" { return .memoryMd }
        // wiki/{entities,concepts,syntheses}/{name}.md
        let wikiPrefixes = ["wiki/entities/", "wiki/concepts/", "wiki/syntheses/"]
        for prefix in wikiPrefixes {
            if relPath.hasPrefix(prefix), relPath.hasSuffix(".md") {
                return .wikiMemory
            }
        }
        return .plainNote
    }

    /// 是否允许重命名这个文件
    public static func canRename(relPath: String) -> Bool {
        switch classify(relPath: relPath) {
        case .raw: return false       // 永远不动
        case .wikiMemory, .memoryMd, .plainNote: return true
        }
    }

    /// 算出显示标题（用在 EditorPane header / sidebar / 任何"显示标题"位置）。
    /// 解析顺序：
    ///   1. frontmatter.title（如果存在且非空）
    ///   2. 第一个 H1（`# xxx`，非空）
    ///   3. 文件名去掉 .md 后的部分（plainNote / memoryMd 适用；wiki 跳过这步）
    public static func displayTitle(
        relPath: String,
        frontmatter: FrontmatterParser.Document? = nil,
        body: String? = nil
    ) -> String {
        if classify(relPath: relPath) == .raw {
            // raw 文件不解析 frontmatter，标题就是文件名
            return (relPath as NSString).lastPathComponent
        }
        if let title = frontmatter?.fields["title"], !title.asString.isEmpty {
            return title.asString
        }
        if let h1 = firstH1(body ?? ""), !h1.isEmpty {
            return h1
        }
        // fallback
        let filename = (relPath as NSString).lastPathComponent
        if filename.hasSuffix(".md") {
            return String(filename.dropLast(3))
        }
        return filename
    }

    /// 从 body 找第一个 `# xxx`（H1），strip 前缀后返内容
    public static func firstH1(_ body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# "), !trimmed.hasPrefix("## ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 给定 plainNote 的显示标题，建议的"安全"文件名（kebab-case）。
    /// 规则：去掉 # / ? / 特殊字符，空格转 `-`，小写。
    /// 不调用 — 仅作为"用户重命名"建议；不强制（arch doc 0.4 "功能克制"）。
    public static func suggestFilename(from displayTitle: String) -> String {
        let lowered = displayTitle.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let replaced = lowered.map { c -> Character in
            if allowed.contains(c) { return c }
            if c == " " || c == "_" { return "-" }
            return "-"  // 其他字符全替成 -
        }
        // 合并连续 -，去首尾 -
        var result = ""
        var lastWasDash = false
        for c in replaced {
            if c == "-" {
                if !lastWasDash && !result.isEmpty {
                    result.append(c)
                }
                lastWasDash = true
            } else {
                result.append(c)
                lastWasDash = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-")) + ".md"
    }
}
