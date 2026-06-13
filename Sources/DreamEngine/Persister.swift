import Foundation

/// dream 第 4 步：把整合与衰减的结果写回 vault。
///
/// 职责（对应架构第 3 节 Persist + llm_wiki 的"增量编译"思想）：
/// 1. durable 教训**增量合并**进 MEMORY.md——按 memory id 锚点更新/新增/移除，
///    不是追加；引擎只动 `dream:begin/end` 标记之间的托管区，区外内容不碰。
/// 2. 为 durable 记忆维护 wiki 页（wiki/concepts/），用 KnowledgeGraph 的
///    Adamic-Adar 打分生成"相关 [[links]]"，并回写 inboundLinks。
/// 3. 被衰减降级的记忆移入 wiki/archive/（写归档页、删 concepts 页），不删内容。
/// 4. 产出 dream-report.md 到 .dream/reports/，并持久化 .dream/ledger.json。
/// 5. 若注入了 GitRunner，最后整体 commit（git 是事务边界）。
public struct Persister {

    public let vaultRoot: URL
    /// 注入则 persist 末尾自动 commit；DreamCycle 注入它并在外层做失败回滚
    public let git: GitRunner?

    public init(vaultRoot: URL, git: GitRunner? = nil) {
        self.vaultRoot = vaultRoot
        self.git = git
    }

    // MARK: - 输入 / 产物

    public struct Input {
        /// 合并完成的完整账本（含新教训与建好的矛盾链接），Persister 在其上应用衰减动作
        public var ledger: Ledger
        public var decayResults: [DecayResult]
        /// 本次整合通过的新教训（报告用）
        public var newlyAccepted: [Memory]
        /// 本次收集过的 raw 相对路径（commit 成功即视为 processed）
        public var gatheredFiles: [String]
        public var now: Date
        /// P8: 脱敏命中统计（每类多少处）。空 = 未启用或没命中。
        public var redactionCounts: [String: Int]
        /// P0-1: 矛盾检测预筛统计 (nil = 这次没新候选, 没跑 link)
        public var prescreenStats: DreamCycle.PrescreenStats?
        /// P0-3: 假 excerpt 闸门拒收数 (0 = 全通过)
        public var rejectedFabricatedCount: Int

        public init(ledger: Ledger, decayResults: [DecayResult] = [],
                    newlyAccepted: [Memory] = [], gatheredFiles: [String] = [],
                    redactionCounts: [String: Int] = [:],
                    prescreenStats: DreamCycle.PrescreenStats? = nil,
                    rejectedFabricatedCount: Int = 0,
                    now: Date = Date()) {
            self.ledger = ledger; self.decayResults = decayResults
            self.newlyAccepted = newlyAccepted; self.gatheredFiles = gatheredFiles
            self.redactionCounts = redactionCounts
            self.prescreenStats = prescreenStats
            self.rejectedFabricatedCount = rejectedFabricatedCount
            self.now = now
        }
    }

    public struct Outcome {
        public let memoryMdPath: String
        public let reportPath: String
        public let wikiPagesWritten: [String]
        public let archivedIDs: [String]
        public let needsReviewIDs: [String]
        /// persist 后的最终账本（状态已更新、inboundLinks 已回写）
        public let ledger: Ledger
        /// 是否产生了 git commit（注入 GitRunner 且有变更时为 true）
        public let committed: Bool
    }

    // MARK: - 主入口

    public func persist(_ input: Input) throws -> Outcome {
        var ledger = input.ledger

        // 0. 确保 wiki/ 下 4 个子目录都存在（架构文档第 1 节）：
        //    entities / concepts / syntheses / archive
        try ensureWikiDirs()

        // 1. 应用衰减动作：archive → 降级（绝不物理删除）；needsReview 只记录、交人工
        let actionByID = Dictionary(uniqueKeysWithValues: input.decayResults.map { ($0.memoryID, $0.action) })
        var archivedIDs: [String] = []
        var needsReviewIDs: [String] = []
        for i in ledger.memories.indices {
            switch actionByID[ledger.memories[i].id] {
            case .archive:
                ledger.memories[i].status = .archived
                archivedIDs.append(ledger.memories[i].id)
            case .needsReview:
                needsReviewIDs.append(ledger.memories[i].id)
            default: break
            }
        }

        // 2. 知识图谱：非归档记忆参与建图（来源重叠连边），算相关链接
        let active = ledger.memories.filter { $0.status != .archived }
        let graph = KnowledgeGraph(memories: active)
        var relatedByID: [String: [(id: String, score: Double)]] = [:]
        var inbound: [String: Int] = [:]
        for m in active {
            let related = graph.topRelated(to: m.id, limit: 5)
            relatedByID[m.id] = related
            for r in related { inbound[r.id, default: 0] += 1 }
        }
        for i in ledger.memories.indices {
            ledger.memories[i].inboundLinks = inbound[ledger.memories[i].id] ?? 0
        }

        // 2b. 矛盾建链：把 contradicts 同步进 relatedTo（双向），并把相关条目的
        //     relatedTo 也补上 id。避免扫整盘 graph 算 related 时再去 lookup。
        syncRelatedTo(in: &ledger.memories)

        // 3. wiki 页：durable 按 kind 写到 entities/concepts/syntheses 对应目录；
        //    归档的写到 archive/，并删除原 kind 目录的页（如果有的话）。
        var wikiWritten: [String] = []
        let textByID = Dictionary(uniqueKeysWithValues: ledger.memories.map { ($0.id, $0.text) })
        // kindByID 让 wikilink 渲染时知道对方在哪个子目录 → 双向 contradicts 链接
        // 才能正确写成 `[[wiki/{kind(b)}/{b}]]`，而不是 fallback 到 concepts/。
        let kindByID = Dictionary(uniqueKeysWithValues: ledger.memories.map { ($0.id, $0.kind) })
        for m in ledger.memories where m.status == .durable {
            let rel = Self.wikiRelPath(for: m)
            try write(wikiPage(for: m, related: relatedByID[m.id] ?? [], textByID: textByID,
                               now: input.now, kindByID: kindByID), to: rel)
            wikiWritten.append(rel)
        }
        for m in ledger.memories where archivedIDs.contains(m.id) {
            let rel = "wiki/archive/\(m.id).md"
            try write(archivePage(for: m, now: input.now), to: rel)
            wikiWritten.append(rel)
            // 归档后从原 kind 目录删页（可能在 entities/concepts/syntheses 任一处）
            for kind in MemoryKind.allCases {
                let oldPage = vaultRoot.appendingPathComponent(Self.wikiRelPath(for: m, kind: kind))
                try? FileManager.default.removeItem(at: oldPage)
            }
        }

        // 4. MEMORY.md 增量合并（非追加）
        let durables = ledger.memories.filter { $0.status == .durable }
        let memoryMdRel = "MEMORY.md"
        let merged = Self.mergeMemoryMd(
            existing: (try? String(contentsOf: vaultRoot.appendingPathComponent(memoryMdRel),
                                   encoding: .utf8)),
            durables: durables)
        try write(merged, to: memoryMdRel)

        // 5. ledger + processed 登记 + dream-report
        try Self.saveLedger(ledger, vaultRoot: vaultRoot)
        if !input.gatheredFiles.isEmpty {
            var registry = Gatherer.loadProcessedRegistry(vaultRoot: vaultRoot)
            registry.formUnion(input.gatheredFiles)
            try Gatherer.saveProcessedRegistry(registry, vaultRoot: vaultRoot)
        }
        let reportRel = ".dream/reports/dream-report-\(Self.stamp(input.now)).md"
        try write(report(input: input, archivedIDs: archivedIDs,
                         needsReviewIDs: needsReviewIDs, durableCount: durables.count),
                  to: reportRel)

        // 6. 注入了 GitRunner 则整体提交
        var committed = false
        if let git {
            committed = try git.commitAll(
                message: "dream: \(Self.stamp(input.now)) gathered=\(input.gatheredFiles.count) "
                       + "accepted=\(input.newlyAccepted.count) archived=\(archivedIDs.count)")
        }

        return Outcome(memoryMdPath: vaultRoot.appendingPathComponent(memoryMdRel).path,
                       reportPath: vaultRoot.appendingPathComponent(reportRel).path,
                       wikiPagesWritten: wikiWritten,
                       archivedIDs: archivedIDs,
                       needsReviewIDs: needsReviewIDs,
                       ledger: ledger,
                       committed: committed)
    }

    // MARK: - MEMORY.md 增量合并

    static let beginMark = "<!-- dream:begin -->"
    static let endMark = "<!-- dream:end -->"

    /// 把 durable 教训合并进 MEMORY.md 的托管区：
    /// - 已存在的 id：保持原有顺序，内容以最新为准（更新而非重复追加）
    /// - 新 id：追加到托管区末尾
    /// - 不再 durable 的 id：从托管区移除（已归档/降级）
    /// - 托管区之外的内容（用户手写部分）原样保留
    static func mergeMemoryMd(existing: String?, durables: [Memory]) -> String {
        let durableByID = Dictionary(uniqueKeysWithValues: durables.map { ($0.id, $0) })

        // 现有托管区中的 id 顺序
        var orderedIDs: [String] = []
        var head = "# MEMORY\n\n> 托管区（dream:begin/end 之间）由 DreamEngine 增量维护，请勿手改；区外内容随意。\n\n"
        var tail = "\n"
        if let existing,
           let beginRange = existing.range(of: beginMark),
           let endRange = existing.range(of: endMark, range: beginRange.upperBound..<existing.endIndex) {
            head = String(existing[..<beginRange.lowerBound])
            tail = String(existing[endRange.upperBound...])
            let block = String(existing[beginRange.upperBound..<endRange.lowerBound])
            for line in block.components(separatedBy: "\n") {
                if let id = extractMemoryID(line) { orderedIDs.append(id) }
            }
        } else if let existing {
            // 已有文件但无托管区：保留全文，把托管区接在末尾
            head = existing.hasSuffix("\n") ? existing + "\n" : existing + "\n\n"
            tail = "\n"
        }

        var finalIDs = orderedIDs.filter { durableByID[$0] != nil }       // 移除不再 durable 的
        for m in durables where !finalIDs.contains(m.id) { finalIDs.append(m.id) }  // 新增的追加

        let lines = finalIDs.compactMap { durableByID[$0].map(renderMemoryLine) }
        let block = ([beginMark] + lines + [endMark]).joined(separator: "\n")
        return head + block + tail
    }

    /// 一条 durable 教训在 MEMORY.md 中的渲染：单行 bullet + 来源 + id 锚点
    static func renderMemoryLine(_ m: Memory) -> String {
        let text = m.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let srcs = m.sources.map { "\($0.file):\($0.line)" }.joined(separator: ", ")
        return "- \(text) — 来源: \(srcs) <!-- memory:\(m.id) -->"
    }

    static func extractMemoryID(_ line: String) -> String? {
        guard let r = line.range(of: #"<!-- memory:([^ ]+) -->"#, options: .regularExpression)
        else { return nil }
        return String(line[r].dropFirst("<!-- memory:".count).dropLast(" -->".count))
    }

    // MARK: - wiki 页渲染

    /// 把 memory id 映射到对应 wiki 子目录的相对路径（arch doc 第 1 节三目录约定）。
    /// 传 `kind:` 时按指定 kind 走（用于"归档时从原 kind 目录删旧页"），不传则按 m.kind。
    /// 注意：**m.status==.archived 不应让本函数返回 archive/ 路径** —— 归档页由 caller
    /// 显式写到 archive/，本函数仅用于"按 kind 删除原页"等 kind-aware 场景。
    static func wikiRelPath(for m: Memory, kind: MemoryKind? = nil) -> String {
        let k = kind ?? m.kind
        switch k {
        case .entity:    return "wiki/entities/\(m.id).md"
        case .concept:   return "wiki/concepts/\(m.id).md"
        case .synthesis: return "wiki/syntheses/\(m.id).md"
        }
    }

    /// dream 第 0 步：保证 4 个 wiki 子目录都存在（arch doc 第 1 节硬性要求）
    func ensureWikiDirs() throws {
        for sub in ["wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive"] {
            let url = vaultRoot.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 矛盾 / 相关链接双向同步：把 a.contradicts 里的 id 也加进 b.contradicts
    /// （双向），并把所有 contradicts / relatedTo id 也补进双方的 relatedTo
    /// （统一以 relatedTo 表达"互相引用"，避免 wikilink 渲染时再扫 graph）。
    /// 收敛迭代 ≤8 次，复杂度 O(N²) 但 memories 通常 < 1k。
    func syncRelatedTo(in memories: inout [Memory]) {
        var byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        var changed = true
        var iter = 0
        while changed && iter < 8 {
            changed = false
            iter += 1
            for a in byID.values {
                // 1. contradicts 双向补齐
                for b in a.contradicts where byID[b] != nil && !byID[b]!.contradicts.contains(a.id) {
                    byID[b]!.contradicts.append(a.id)
                    changed = true
                }
                // 2. contradicts 同时也是 relatedTo 的一种：补到双方 relatedTo
                for b in a.contradicts where byID[b] != nil && !byID[b]!.relatedTo.contains(a.id) {
                    byID[b]!.relatedTo.append(a.id)
                    changed = true
                }
                for b in a.contradicts where byID[b] != nil && !a.relatedTo.contains(b) {
                    byID[a.id]!.relatedTo.append(b)
                    changed = true
                }
                // 3. relatedTo 双向补齐
                for b in a.relatedTo where byID[b] != nil && !byID[b]!.relatedTo.contains(a.id) {
                    byID[b]!.relatedTo.append(a.id)
                    changed = true
                }
            }
        }
        memories = Array(byID.values)
    }

    /// 把对方 id 渲染成可点击的 wikilink：知道对方在哪个 kind 子目录就写到对应路径，
    /// 不知道则默认 wiki/concepts/。这样 ## 相关 和 ## 矛盾 双向都能正确跳转。
    static func wikilink(forMemoryID id: String, kindByID: [String: MemoryKind]) -> String {
        let path: String
        if let k = kindByID[id] {
            switch k {
            case .entity:    path = "wiki/entities/\(id)"
            case .concept:   path = "wiki/concepts/\(id)"
            case .synthesis: path = "wiki/syntheses/\(id)"
            }
        } else {
            path = "wiki/concepts/\(id)"
        }
        return "[[\(path)]]"
    }

    func wikiPage(for m: Memory, related: [(id: String, score: Double)],
                  textByID: [String: String], now: Date,
                  kindByID: [String: MemoryKind] = [:]) -> String {
        var out = """
        ---
        memory: \(m.id)
        kind: \(m.kind.rawValue)
        status: \(m.status.rawValue)
        decayClass: \(m.decayClass.rawValue)
        updated: \(Self.stamp(now))
        ---

        # \(String(m.text.replacingOccurrences(of: "\n", with: " ").prefix(60)))

        \(m.text)

        ## 来源
        \(m.sources.map { "- \($0.file):\($0.line) — \($0.excerpt)" }.joined(separator: "\n"))
        """
        if !related.isEmpty {
            out += "\n\n## 相关\n"
            out += related.map { r in
                let hint = textByID[r.id].map { String($0.prefix(40)) } ?? ""
                return "- \(Self.wikilink(forMemoryID: r.id, kindByID: kindByID)) (AA \(String(format: "%.2f", r.score))) \(hint)"
            }.joined(separator: "\n")
        }
        if !m.contradicts.isEmpty {
            out += "\n\n## contradicts\n"
            out += m.contradicts.map { "- \(Self.wikilink(forMemoryID: $0, kindByID: kindByID))" }.joined(separator: "\n")
        }
        return out + "\n"
    }

    func archivePage(for m: Memory, now: Date) -> String {
        """
        ---
        memory: \(m.id)
        status: archived
        archivedAt: \(Self.stamp(now))
        ---

        # [已归档] \(String(m.text.replacingOccurrences(of: "\n", with: " ").prefix(60)))

        \(m.text)

        ## 来源
        \(m.sources.map { "- \($0.file):\($0.line)" }.joined(separator: "\n"))

        > 因显著度衰减被降级，未删除；可 grep、可在 git 历史找回。
        """
    }

    // MARK: - dream-report

    func report(input: Input, archivedIDs: [String], needsReviewIDs: [String],
                durableCount: Int) -> String {
        let accepted = input.newlyAccepted
        var out = """
        # Dream Report — \(Self.stamp(input.now))

        ## 概览
        - 收集 raw 文件: \(input.gatheredFiles.count)
        - 新教训通过整合: \(accepted.count)（durable \(accepted.filter { $0.status == .durable }.count) / candidate \(accepted.filter { $0.status == .candidate }.count)）
        - 本次归档(降级): \(archivedIDs.count)
        - 待人工裁决(矛盾): \(needsReviewIDs.count)
        - MEMORY.md 当前 durable 总数: \(durableCount)
        """
        if !input.gatheredFiles.isEmpty {
            out += "\n\n## 收集\n" + input.gatheredFiles.map { "- \($0)" }.joined(separator: "\n")
        }
        if !accepted.isEmpty {
            out += "\n\n## 新教训\n" + accepted.map {
                "- [\($0.status.rawValue)] \(String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(80))) <!-- memory:\($0.id) -->"
            }.joined(separator: "\n")
        }
        if !archivedIDs.isEmpty {
            out += "\n\n## 归档\n" + archivedIDs.map { "- [[\($0)]] → wiki/archive/" }.joined(separator: "\n")
        }
        if !needsReviewIDs.isEmpty {
            out += "\n\n## 待裁决\n" + needsReviewIDs.map { "- [[\($0)]] 存在矛盾链接" }.joined(separator: "\n")
        }
        // P8: 脱敏命中统计
        // 让用户在 dream-report 里直接看到"今天 N 条 [REDACTED_XXX]"，
        // 用于发现 CN_ID_CARD 误伤长数字串这类规则问题。
        // 排序：按命中次数从高到低
        let sortedCounts = input.redactionCounts.sorted { $0.value > $1.value }
        if !sortedCounts.isEmpty {
            let total = sortedCounts.reduce(0) { $0 + $1.value }
            out += "\n\n## Redaction（脱敏命中）\n"
            out += "本轮共 \(total) 处脱敏命中（仅 redactBeforeConsolidate=true 时统计）：\n"
            for (label, count) in sortedCounts {
                out += "- [REDACTED_\(label)]: \(count) 处\n"
            }
        } else {
            out += "\n\n## Redaction\n本轮无脱敏命中（redactBeforeConsolidate=false 或 raw 无敏感字段）\n"
        }
        // P0-1: 矛盾检测预筛统计
        if let ps = input.prescreenStats {
            out += "\n\n## Prescreen（矛盾检测预筛）\n"
            out += "本轮 \(ps.candidatesCount) 个新候选 × \(ps.existingCount) 个现有 durable\n"
            out += "- 预筛留下: \(ps.keptByScreener) 对（共享实体 token / Adamic-Adar>0）\n"
            out += "- 实际调 LLM: \(ps.llmCalls) 次（上限 \(ps.maxPairsPerNight)）\n"
            if ps.truncated > 0 {
                out += "- ⚠️ 截断: \(ps.truncated) 对**未比对**，明晚继续\n"
            }
        }
        // P0-3: 假 excerpt 闸门拒收统计 (deterministic, 0 LLM)
        if input.rejectedFabricatedCount > 0 {
            out += "\n\n## Fabrication（假 excerpt 拒收）\n"
            out += "本轮拒收 **\(input.rejectedFabricatedCount)** 条 fabricated draft（其 sourceExcerpt 归一化后不在源文件真实内容里）\n"
            out += "这些 draft 引用了真文件 + 假片段, verify 自我校验骗自己. P0-3 闸门在 3 段 CoT 的 generate 步骤之后拦截, 永不写进 ledger.\n"
        }
        return out + "\n"
    }

    // MARK: - ledger 读写（.dream/ledger.json，ISO8601 日期，便于人读与 diff）

    public static func ledgerURL(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".dream/ledger.json")
    }

    public static func loadLedger(vaultRoot: URL) -> Ledger {
        let url = ledgerURL(vaultRoot: vaultRoot)
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Ledger.self, from: data)) ?? Ledger()
    }

    public static func saveLedger(_ ledger: Ledger, vaultRoot: URL) throws {
        let url = ledgerURL(vaultRoot: vaultRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(ledger)
        // P7-T3: 写 tmp + atomic rename 防止崩了写一半
        try AtomicFile.write(data: data, to: url)
    }

    // MARK: - 工具

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func write(_ content: String, to relPath: String) throws {
        let url = vaultRoot.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
