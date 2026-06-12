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
///
/// 架构文档冲突的取舍（deliverable.md 详述）：
///   - 第 3.1 节"raw 候选标 processed:true" 与第 0.1 节"raw/ 永远只读" 冲突。
///   - 本实现以第 0.1 节优先：raw/ 在文件系统层挂为只读（见 RawReadonlyGuard），
///     Gatherer 永不写回 raw；processed 状态唯一来源是 `.dream/processed.json`。
///   - 防御性接口 `assertWillNotWriteBackToRaw(vaultRoot:)`：任何未来"想往 raw 写"
///     的代码路径都应先调它；若 raw 已被挂只读，立即抛 `attemptToModifyRaw`。
public struct Gatherer {

    /// Gatherer 抛出的错误。`attemptToModifyRaw` 是对架构原则 1 的硬保险：
    /// 若 raw/ 已被挂只读，任何想把 processed 写回 raw 的尝试都立刻抛错，
    /// 不让"原则 1 变成机制"被旁路。
    public enum GathererError: Error, CustomStringConvertible, Equatable {
        /// 调用方尝试在 raw/ 已挂只读时把 processed 写回 raw 文件。
        case attemptToModifyRaw(file: String)

        public var description: String {
            switch self {
            case .attemptToModifyRaw(let file):
                return "Gatherer: 试图把 processed 写回 raw/\(file) —— raw/ 在文件系统层已挂只读（架构原则 1）。已处理状态应写入 .dream/processed.json 而非 raw frontmatter。"
            }
        }
    }

    /// 防御性闸门：raw/ 已被 RawReadonlyGuard 挂只读时，任何想要"写回 raw"的
    /// 代码路径都应先调本函数。它会在 raw 是只读状态时立刻抛错。
    ///
    /// 当前实现里 Gatherer.gather() 不写回 raw（processed 状态走 .dream/processed.json），
    /// 所以这个闸门更多是给"未来可能的 refactor"留的兜底：
    /// 一旦有人加回"写 processed:true 到 raw"的逻辑，先撞到这里就会立刻炸。
    ///
    /// - Parameter vaultRoot: vault 根目录
    /// - Parameter file: 试图写回的 raw 文件名（仅用于错误信息）
    public static func assertWillNotWriteBackToRaw(vaultRoot: URL, file: String) throws {
        if RawReadonlyGuard.isReadonly(vaultRoot: vaultRoot) {
            throw GathererError.attemptToModifyRaw(file: file)
        }
    }

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
        /// P8: 脱敏命中统计（每类多少处）。为空 = 没启用 redactBeforeConsolidate / 没命中。
        public let redactionCounts: [String: Int]
    }

    /// 扫描 raw/，返回脱敏后的候选 Memory 列表。
    /// 每个未处理文件产出一条 candidate Memory：text = 脱敏后的正文（去 frontmatter），
    /// source = 该文件 + 正文起始行 + 脱敏后的开头片段。
    public func gather() throws -> GatherResult {
        let fm = FileManager.default
        let rawDir = vaultRoot.appendingPathComponent(rawSubdir)
        guard fm.fileExists(atPath: rawDir.path) else {
            return GatherResult(candidates: [], gatheredFiles: [], redactionCounts: [:])
        }
        let processed = Self.loadProcessedRegistry(vaultRoot: vaultRoot)

        let files = try fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var candidates: [Memory] = []
        var gathered: [String] = []
        var redactionCounts: [String: Int] = [:]

        for file in files {
            let relPath = "\(rawSubdir)/\(file.lastPathComponent)"
            guard !processed.contains(relPath) else { continue }
            let content = try String(contentsOf: file, encoding: .utf8)
            let doc = Self.parseFrontmatter(content)
            // frontmatter 协议（arch doc 0.1 / §1）：
            //   - 显式 `processed: false` → 待处理，必收
            //   - 显式 `processed: true`  → 已处理，跳过
            //   - 无 frontmatter           → 保守按"未声明"对待（任何没主动标记
            //                                 处理过的 raw 文件都应被 dream 看到）
            let flag = doc.fields["processed"]?.lowercased()
            if flag == "true" { continue }

            let body = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let report = redactor.redact(body)
            let redactedBody = report.redactedText
            // P8: 累加脱敏命中次数，dream-report 会写出来给用户审查
            for (label, count) in report.counts {
                redactionCounts[label, default: 0] += count
            }
            let excerpt = String(redactedBody.prefix(200))

            candidates.append(Memory(
                text: redactedBody,
                sources: [SourceRef(file: relPath, line: doc.bodyStartLine, excerpt: excerpt)],
                status: .candidate))
            gathered.append(relPath)
        }
        return GatherResult(candidates: candidates,
                            gatheredFiles: gathered,
                            redactionCounts: redactionCounts)
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

    // MARK: - P3-T5: 给 VaultStatus.load 用的 frontmatter 判定 helper
    /// 是否应被 dream 处理（三分支语义，与 gather() 内一致）。
    ///   - 显式 `processed: false` → true
    ///   - 显式 `processed: true`  → false
    ///   - 无 frontmatter           → true（保守按"未声明"对待）
    public static func shouldProcessRaw(content: String) -> Bool {
        let doc = parseFrontmatter(content)
        let flag = doc.fields["processed"]?.lowercased()
        if flag == "true" { return false }
        return true
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
