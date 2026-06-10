import Foundation

/// dream 第 1 步：收集 raw/ 中未处理的原始日志，脱敏后产出候选 Memory 列表。
///
/// 设计要点（对应架构原则 1：raw/ 永远只读）：
/// - 只读取 frontmatter 标 `processed: false` 的 .md 文件；无 frontmatter 或
///   无 processed 键的文件保守跳过（不猜测用户意图）。
/// - raw/ 只读 ⇒ 不能把 processed 翻成 true 写回原文件。已处理状态记录在
///   `.dream/processed.json`（相对路径列表），由 DreamCycle 在成功 commit 时更新。
///   一个文件是候选，当且仅当 frontmatter 标 processed:false 且不在该清单中。
/// - 进入候选集前先过 Redactor（隐私脱敏只作用于副本，原文件不动）。
public struct Gatherer {

    public let vaultRoot: URL
    public let redactor: Redactor
    /// raw 子目录名，默认 "raw"
    public let rawSubdir: String

    public init(vaultRoot: URL, redactor: Redactor = Redactor(), rawSubdir: String = "raw") {
        self.vaultRoot = vaultRoot
        self.redactor = redactor
        self.rawSubdir = rawSubdir
    }

    /// 一次收集的产物：候选记忆 + 它来自哪个 raw 文件（供 commit 后登记 processed）
    public struct GatherResult: Equatable {
        public let candidates: [Memory]
        /// 本次实际收集到的 raw 相对路径（如 "raw/2026-06-07-claude.md"）
        public let gatheredFiles: [String]
    }

    /// 扫描 raw/，返回脱敏后的候选 Memory 列表。
    /// 每个未处理文件产出一条 candidate Memory：text = 脱敏后的正文（去 frontmatter），
    /// source = 该文件 + 正文起始行 + 脱敏后的开头片段。
    public func gather() throws -> GatherResult {
        let fm = FileManager.default
        let rawDir = vaultRoot.appendingPathComponent(rawSubdir)
        guard fm.fileExists(atPath: rawDir.path) else {
            return GatherResult(candidates: [], gatheredFiles: [])
        }
        let processed = Self.loadProcessedRegistry(vaultRoot: vaultRoot)

        let files = try fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var candidates: [Memory] = []
        var gathered: [String] = []

        for file in files {
            let relPath = "\(rawSubdir)/\(file.lastPathComponent)"
            guard !processed.contains(relPath) else { continue }
            let content = try String(contentsOf: file, encoding: .utf8)
            let doc = Self.parseFrontmatter(content)
            // 只收 frontmatter 显式标 processed:false 的
            guard doc.fields["processed"]?.lowercased() == "false" else { continue }

            let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let redactedBody = redactor.redact(body).redactedText
            let excerpt = String(redactedBody.prefix(200))

            candidates.append(Memory(
                text: redactedBody,
                sources: [SourceRef(file: relPath, line: doc.bodyStartLine, excerpt: excerpt)],
                status: .candidate))
            gathered.append(relPath)
        }
        return GatherResult(candidates: candidates, gatheredFiles: gathered)
    }

    // MARK: - processed 登记（.dream/processed.json，替代写回 raw 的 processed:true）

    public static func processedRegistryURL(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".dream/processed.json")
    }

    public static func loadProcessedRegistry(vaultRoot: URL) -> Set<String> {
        let url = processedRegistryURL(vaultRoot: vaultRoot)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public static func saveProcessedRegistry(_ registry: Set<String>, vaultRoot: URL) throws {
        let url = processedRegistryURL(vaultRoot: vaultRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry.sorted()).write(to: url)
    }

    // MARK: - 轻量 frontmatter 解析（只认 `key: value` 平铺，不做完整 YAML）

    struct ParsedDoc {
        let fields: [String: String]
        let body: String
        let bodyStartLine: Int   // 1-based，正文第一行在原文件中的行号
    }

    static func parseFrontmatter(_ content: String) -> ParsedDoc {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ParsedDoc(fields: [:], body: content, bodyStartLine: 1)
        }
        var fields: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines[(i + 1)...].joined(separator: "\n")
                return ParsedDoc(fields: fields, body: body, bodyStartLine: i + 2)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields[key] = value }
            }
            i += 1
        }
        // 没有闭合 `---`：当作无 frontmatter 处理
        return ParsedDoc(fields: [:], body: content, bodyStartLine: 1)
    }
}
