import Foundation
import AppKit

/// P3-T8: vault 内 md 文件全文搜索。
///
/// 用 `mdfind` 包装 macOS Spotlight 索引（macOS 自带，无需自己造搜索引擎）。
/// 优点：自动索引 md 文本内容，几千条笔记秒级响应。
/// 缺点：依赖用户没禁用 Spotlight 索引；首次 vault 还没建索引时可能漏几条。
@MainActor
public final class VaultSearcher: ObservableObject {
    @Published public private(set) var results: [SearchResult] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public var query: String = ""

    public struct SearchResult: Identifiable, Equatable {
        public let id: String          // relPath
        public let path: URL
        public let snippet: String    // 命中行（截断到 200 字符）
    }

    public init() {}

    /// 启动搜索（异步）。优先 ripgrep（更快更准），fallback mdfind。
    public func search(vaultRoot: URL) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            return
        }
        isSearching = true
        Task.detached { [vaultRoot, q] in
            let results = await Self.runSearch(query: q, vaultRoot: vaultRoot)
            await MainActor.run {
                self.results = results
                self.isSearching = false
            }
        }
    }

    /// P2-6: ripgrep fast-path, mdfind fallback
    private static func runSearch(query: String, vaultRoot: URL) async -> [SearchResult] {
        // 1) ripgrep
        if let hits = RipgrepBridge.search(query: query, root: vaultRoot) {
            return hits.map { hit in
                let url = vaultRoot.appendingPathComponent(hit.file)
                return SearchResult(id: hit.file, path: url, snippet: hit.text)
            }
        }
        // 2) mdfind fallback
        return await runMdfind(query: query, vaultRoot: vaultRoot)
    }

    private static func runMdfind(query: String, vaultRoot: URL) async -> [SearchResult] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                // Spotlight query: 限制到 vault 内
                let onlyText = "kMDItemTextContent == '\(query)'cd"
                p.arguments = ["-onlyin", vaultRoot.path, onlyText]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: [])
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let s = String(data: data, encoding: .utf8) ?? ""
                let paths = s.components(separatedBy: "\n").filter { !$0.isEmpty }
                let results = paths.compactMap { path -> SearchResult? in
                    let url = URL(fileURLWithPath: path)
                    // 拼 snippet
                    let snippet = Self.snippet(url: url, query: query) ?? ""
                    let rel = Self.relPath(of: url, vaultRoot: vaultRoot)
                    return SearchResult(id: rel, path: url, snippet: snippet)
                }
                cont.resume(returning: results)
            }
        }
    }

    private static func snippet(url: URL, query: String) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        // 找第一个含 query 的行（case-insensitive）
        let lowerQ = query.lowercased()
        for line in lines {
            if line.lowercased().contains(lowerQ) {
                return String(line.prefix(200))
            }
        }
        return String(content.prefix(200))
    }

    private static func relPath(of url: URL, vaultRoot: URL) -> String {
        let root = vaultRoot.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(root + "/") {
            return String(p.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }
}
