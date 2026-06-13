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
    /// P3-4 §2.6: 单个 candidate 块大小上限. 默认 4000 字符, 安全线 < Ollama num_ctx=8192
    /// (留 ~50% 给 analyze + generate prompt + 余量). 设大点会丢后半段教训 (静默截断).
    public let maxChunkChars: Int

    public init(vaultRoot: URL,
                redactor: Redactor = Redactor(),
                rawSubdir: String = "raw",
                maxChunkChars: Int = 4000) {
        self.vaultRoot = vaultRoot
        self.redactor = redactor
        self.rawSubdir = rawSubdir
        self.maxChunkChars = maxChunkChars
    }

    /// 一次收集的产物：候选记忆 + 它来自哪个 raw 文件（供 commit 后登记 processed）
    public struct GatherResult: Equatable {
        public let candidates: [Memory]
        /// 本次实际收集到的 raw 相对路径（如 "raw/2026-06-07-claude.md"）
        public let gatheredFiles: [String]
        /// P8: 脱敏命中统计（每类多少处）。为空 = 没启用 redactBeforeConsolidate / 没命中。
        public let redactionCounts: [String: Int]
        /// P0-3: 源文件内容 (relPath -> 脱敏后的 body), 供 SourceRefValidator 闸门
        /// 校验 draft.sourceExcerpt 是否真在源文件里.
        /// nil = 旧格式 (向后兼容) / 文件被删 / 拼装 dummy 时
        public let sourceContents: [String: String]
        /// P3-4 评审 §2.6 修复: 每个文件分块统计 (relPath -> ChunkStat).
        /// dream-report 会读这个字段给用户审查分块数 + 截断告警.
        public let chunkStats: [String: ChunkStat]
    }

    /// P3-4: 单个 raw 文件的分块统计
    /// - `chunks`: 该文件被分成的 candidate 数量 (1 = 不分块)
    /// - `truncated`: 是否因总长 > maxChars 被强制截断 (丢内容告警)
    /// - `originalChars`: 文件 body 原始字符数 (脱敏前)
    public struct ChunkStat: Equatable, Sendable {
        public let chunks: Int
        public let truncated: Bool
        public let originalChars: Int
    }

    /// 扫描 raw/，返回脱敏后的候选 Memory 列表。
    /// 每个未处理文件产出一条 candidate Memory：text = 脱敏后的正文（去 frontmatter），
    /// source = 该文件 + 正文起始行 + 脱敏后的开头片段。
    public func gather() throws -> GatherResult {
        let fm = FileManager.default
        let rawDir = vaultRoot.appendingPathComponent(rawSubdir)
        guard fm.fileExists(atPath: rawDir.path) else {
            return GatherResult(candidates: [], gatheredFiles: [],
                                redactionCounts: [:], sourceContents: [:],
                                chunkStats: [:])
        }
        let processed = Self.loadProcessedRegistry(vaultRoot: vaultRoot)

        let files = try fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var candidates: [Memory] = []
        var gathered: [String] = []
        var redactionCounts: [String: Int] = [:]
        // P0-3: 源文件内容 (relPath -> body), 供 SourceRefValidator 闸门
        var sourceContents: [String: String] = [:]
        // P3-4 §2.6: 每个文件分块统计, dream-report 给用户审查分块数 + 截断告警
        var chunkStats: [String: ChunkStat] = [:]

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
            // P3-4 §2.6: 按 markdown `## `/`### ` 标题分块, 超 maxChunkChars 强制切分.
            // 每块产出 1 个 candidate Memory, line 是块在原文件的起始行号.
            // 没标题的纯文本文件作为单块 (1 candidate).
            // P0-3 闸门 substring check: 块内容必须真在 sourceContents[relPath] (= redactedBody) 里.
            // - 用 redactedBody (脱敏后) 存 sourceContents (P0-3 闸门要)
            // - 块用 redactedBody.split 后的子串 (P0-3 substring 必过)
            let chunks = Self.chunkBody(redactedBody, maxChars: maxChunkChars)
            let chunked = Self.annotateChunksWithLineNumbers(
                chunks: chunks,
                fullBody: redactedBody,
                bodyStartLine: doc.bodyStartLine)
            // truncated: 原始 body 超 maxChars 触发 force-split (1 H2 块被切成 ≥2 块)
            // OR 总长 > maxChars (整文件超, 需用户审查)
            let truncated = redactedBody.count > maxChunkChars
            chunkStats[relPath] = ChunkStat(
                chunks: chunked.count,
                truncated: truncated,
                originalChars: redactedBody.count)
            for (chunkText, chunkLine) in chunked {
                // P0-3: excerpt 真实化 (= chunkText), 不再恒 200 字符.
                // sourceContents[relPath] 仍是整 redactedBody, substring check 必过.
                candidates.append(Memory(
                    text: chunkText,
                    sources: [SourceRef(file: relPath, line: chunkLine, excerpt: chunkText)],
                    status: .candidate))
            }
            gathered.append(relPath)
            // P0-3: 把脱敏后的 body 存进 sourceContents (供 SourceRefValidator 校验)
            sourceContents[relPath] = redactedBody
        }
        return GatherResult(candidates: candidates,
                            gatheredFiles: gathered,
                            redactionCounts: redactionCounts,
                            sourceContents: sourceContents,
                            chunkStats: chunkStats)
    }

    // MARK: - P3-4 §2.6: chunking (按 markdown 标题分块, 超 maxChars 强制切分)

    /// 把单个 raw 文件的脱敏 body 按 markdown `## `/`### ` 标题分块.
    /// 行为:
    /// - 总长 ≤ maxChars: 1 块 (不分块, 不管有几个 H2)
    /// - 总长 > maxChars: 按 `## ` split (1 块 = 1 标题 + 1 内容, 留 1 块给 intro)
    /// - 无 H2 但 > maxChars: 整段 1 块 (由外层 force-split 处理)
    /// - 单块 > maxChars: 强制按 "\n" 切 (避免切到单词中间)
    /// - 空文本: 0 块 (上游 gather() 已过滤)
    ///
    /// P3-4 设计取舍:
    /// - 用 `## ` 不用 `# `: H1 是文件 title, 不应 split. H2 是真正的章节.
    /// - 不 trim chunk leading whitespace: 块要保留原行号, 不能 trim 后偏移.
    static func chunkBody(_ body: String, maxChars: Int) -> [String] {
        guard !body.isEmpty else { return [] }
        // 短文本不分块: 短 raw (≤ maxChars) 不应被 H2 split 拆得七零八落 (e.g. 300 字符的
        // 短笔记里含 2 个 H2, 不应产 2 个 candidate 浪费 LLM 算力).
        if body.count <= maxChars {
            return [body]
        }
        // 长文本: 按 `## ` split. 1 块 = 1 标题 + 1 内容. intro (开头没标题) = 1 块.
        var pieces: [String] = []
        var current = ""
        let lines = body.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("## ") && !current.isEmpty {
                pieces.append(current)
                current = line
            } else {
                if current.isEmpty {
                    current = line
                } else {
                    current += "\n" + line
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        // 单块可能超 maxChars (Claude session 一节 50KB).
        // 超 maxChars → 强制按 maxChars 切 (优先 "\n" 切, 避免切到单词中间).
        var result: [String] = []
        for piece in pieces {
            if piece.count <= maxChars {
                result.append(piece)
            } else {
                var remaining = piece
                while remaining.count > maxChars {
                    let cutIdx = remaining.index(remaining.startIndex, offsetBy: maxChars)
                    let cutSub = remaining[..<cutIdx]
                    // 找最近的 "\n" 切 → cut AFTER the "\n" (保留词完整)
                    if let lastNL = cutSub.lastIndex(of: "\n") {
                        // up to and INCLUDING "\n" (so chunk ends with "\n", 下块从词首开始)
                        result.append(String(remaining[..<remaining.index(after: lastNL)]))
                        remaining = String(remaining[remaining.index(after: lastNL)...])
                    } else {
                        // 没换行 → 硬切
                        result.append(String(cutSub))
                        remaining = String(remaining[cutIdx...])
                    }
                }
                if !remaining.isEmpty { result.append(remaining) }
            }
        }
        return result
    }

    /// 给每个 chunk 标注在原文件中的起始行号 (1-based).
    /// 算法: 累加 line 数 (每个 chunk 第一行 = 在 redactedBody 里的行号 + bodyStartLine).
    /// P0-3 闸门 substring check: chunkText 是 redactedBody 的子串, 必过.
    static func annotateChunksWithLineNumbers(
        chunks: [String],
        fullBody: String,
        bodyStartLine: Int
    ) -> [(text: String, line: Int)] {
        guard !chunks.isEmpty else { return [] }
        var result: [(text: String, line: Int)] = []
        var searchStart = fullBody.startIndex
        for chunk in chunks {
            // 找 chunk 在 fullBody 的起始 offset
            let range = fullBody.range(of: chunk, range: searchStart..<fullBody.endIndex)
            let offset: String.Index
            if let r = range {
                offset = r.lowerBound
            } else {
                // 找不到 (极端 case, e.g. chunk 被 trim 过). fallback 拿前面 chunk 的结束位置.
                offset = searchStart
            }
            // 算行号: fullBody 从 start 到 offset 的 "\n" 数 + bodyStartLine
            let prefix = fullBody[fullBody.startIndex..<offset]
            let lineOffset = prefix.components(separatedBy: "\n").count - 1
            let lineNumber = bodyStartLine + lineOffset
            result.append((chunk, lineNumber))
            // 推进 searchStart (避免同一 chunk 反复 match)
            if let r = range {
                searchStart = r.upperBound
            }
        }
        return result
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
