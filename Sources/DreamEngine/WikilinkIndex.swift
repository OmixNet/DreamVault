import Foundation

/// Vault 范围 wikilink 索引（arch doc 不强制 schema，但编辑器需要跳转/反向链接）。
///
/// Wikilink 形式：
///   - `[[id]]`           → target = "id", label = "id"
///   - `[[id|alias]]`     → target = "id", label = "alias"
///   - `[[wiki/kind/id]]` → target = "wiki/kind/id"（保留子路径）
///
/// 索引内容：
///   - 扫一遍 vault 内所有 .md 文件
///   - 抽每个文件的 outlinks（[[...]] 出现 → target）
///   - 反向：target → [source files]
///
/// 性能：vault 通常 < 1k 文件，单遍 O(N*L) 完全够用。后续如需要用 LRU cache。
public struct WikilinkIndex {

    public struct Entry: Equatable, Sendable {
        public let file: URL       // 源文件（绝对路径）
        public let relPath: String   // 相对 vaultRoot 的路径
        public let outlinks: [Link]  // 文件里出现的 wikilink
        public let backLinksCount: Int  // 反向链接数（冗余字段，避免客户端再算一次）

        public struct Link: Equatable, Sendable {
            public let target: String
            public let label: String
            public let line: Int     // 1-based
        }
    }

    /// 单文件 → wikilink 条目
    public private(set) var entries: [String: Entry] = [:]
    /// target → [source relPath]  反向索引
    public private(set) var backLinks: [String: [String]] = [:]
    /// 所有出现过的 target（不区分大小写）
    public var allTargets: Set<String> { Set(backLinks.keys) }

    public init() {}

    /// 扫 vault 内所有 .md 文件（递归），建索引。
    /// 排除 raw/（arch doc 0.1 raw 永远只读、不参与 wiki 链接）。
    public mutating func scan(vaultRoot: URL) throws {
        entries = [:]
        backLinks = [:]
        let fm = FileManager.default
        // 扫 wiki/ MEMORY.md 和顶层 .md（不含 raw/）
        let candidates = try findMarkdownFiles(vaultRoot: vaultRoot, fm: fm)
        for url in candidates {
            let rel = Self.relativePath(url: url, vaultRoot: vaultRoot)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let links = Self.extractWikilinks(from: content)
            let entry = Entry(file: url, relPath: rel, outlinks: links, backLinksCount: 0)
            entries[rel] = entry
            for link in links {
                backLinks[link.target, default: []].append(rel)
            }
        }
        // 重写：每 entry 算
        for (rel, _) in entries {
            var count = 0
            for (_, sources) in backLinks {
                if sources.contains(rel) { count += 1 }
            }
            let old = entries[rel]!
            entries[rel] = Entry(file: old.file, relPath: old.relPath,
                                 outlinks: old.outlinks, backLinksCount: count)
        }
    }

    /// 单文件重建（vault 里有文件被改时用，不重扫整个 vault）
    public mutating func updateFile(at url: URL, vaultRoot: URL) throws {
        let rel = Self.relativePath(url: url, vaultRoot: vaultRoot)
        // 先删旧 entry
        if let old = entries.removeValue(forKey: rel) {
            for link in old.outlinks {
                if var sources = backLinks[link.target] {
                    sources.removeAll { $0 == rel }
                    if sources.isEmpty {
                        backLinks.removeValue(forKey: link.target)
                    } else {
                        backLinks[link.target] = sources
                    }
                }
            }
        }
        // 加新 entry
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let links = Self.extractWikilinks(from: content)
        entries[rel] = Entry(file: url, relPath: rel, outlinks: links, backLinksCount: 0)
        for link in links {
            backLinks[link.target, default: []].append(rel)
        }
    }

    /// 移除单文件 entry（文件被删时用）
    public mutating func removeFile(at url: URL, vaultRoot: URL) {
        let rel = Self.relativePath(url: url, vaultRoot: vaultRoot)
        if let old = entries.removeValue(forKey: rel) {
            for link in old.outlinks {
                if var sources = backLinks[link.target] {
                    sources.removeAll { $0 == rel }
                    if sources.isEmpty {
                        backLinks.removeValue(forKey: link.target)
                    } else {
                        backLinks[link.target] = sources
                    }
                }
            }
        }
    }

    /// 给定 target，找所有反向引用它的源文件
    public func backLinks(for target: String) -> [String] {
        backLinks[target] ?? []
    }

    /// 给定 target，检查 vault 内是否存在（模糊匹配：精确 + 大小写不敏感）
    public func resolveTarget(_ target: String) -> String? {
        if entries[target] != nil { return target }
        if backLinks[target] != nil || backLinks[target.lowercased()] != nil {
            return target
        }
        // 大小写不敏感查找
        let lower = target.lowercased()
        for key in backLinks.keys where key.lowercased() == lower {
            return key
        }
        return nil
    }

    // MARK: - 文件扫描

    /// 找 vault 内 .md 文件，**排除** raw/
    private func findMarkdownFiles(vaultRoot: URL, fm: FileManager) throws -> [URL] {
        var results: [URL] = []
        let excludeNames: Set<String> = ["raw", ".git", ".build", ".swiftpm", "node_modules", ".opencode"]
        // 单趟 enumerator（默认包含根 vaultRoot，不需单独 contentsOfDirectory）
        guard let enumerator = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else {
            return results
        }
        for case let url as URL in enumerator {
            let lastComponent = url.lastPathComponent
            if excludeNames.contains(lastComponent) { enumerator.skipDescendants(); continue }
            if url.pathExtension == "md" {
                // 跳过 .dream/reports/（报告不需要 wikilink 索引）
                if url.path.contains("/.dream/reports/") { continue }
                results.append(url)
            }
        }
        return results
    }

    static func relativePath(url: URL, vaultRoot: URL) -> String {
        let abs = url.standardizedFileURL.path
        let root = vaultRoot.standardizedFileURL.path
        if abs.hasPrefix(root + "/") {
            return String(abs.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - Wikilink 抽取

    /// 从一段 markdown 文本中抽 [[...]]。返回 (target, label, line) 列表。
    static func extractWikilinks(from markdown: String) -> [Entry.Link] {
        var results: [Entry.Link] = []
        let lines = markdown.components(separatedBy: "\n")
        for (lineIdx, line) in lines.enumerated() {
            // 用字符数组避免 String.Index 计算复杂度（也不易 OOB）
            let chars = Array(line)
            var i = 0
            while i + 1 < chars.count {
                // 找 [[
                if chars[i] == "[" && chars[i + 1] == "[" {
                    let afterOpen = i + 2
                    // 找 ]]
                    if let closeRel = findSubseq(in: chars, from: afterOpen, sub: ["]", "]"]) {
                        let innerStart = afterOpen
                        let innerEnd = closeRel
                        let inner = String(chars[innerStart..<innerEnd])
                        if !inner.isEmpty {
                            let (target, label) = parseWikilink(inner)
                            results.append(Entry.Link(target: target, label: label, line: lineIdx + 1))
                        }
                        i = closeRel + 2  // 跳过 ]]
                        continue
                    }
                }
                i += 1
            }
        }
        return results
    }

    /// 在 chars[from..<count] 里找 sub 数组。返回 sub 起点下标。
    private static func findSubseq(in chars: [Character], from: Int, sub: [Character]) -> Int? {
        guard !sub.isEmpty else { return nil }
        var i = from
        while i + sub.count <= chars.count {
            if Array(chars[i..<(i + sub.count)]) == sub { return i }
            i += 1
        }
        return nil
    }

    /// [[id|alias]] → ("id", "alias")；[[id]] → ("id", "id")
    static func parseWikilink(_ inner: String) -> (target: String, label: String) {
        if let pipeRange = inner.range(of: "|") {
            return (String(inner[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces),
                    String(inner[pipeRange.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (inner.trimmingCharacters(in: .whitespaces), inner.trimmingCharacters(in: .whitespaces))
    }
}
