import Foundation

// MARK: - DreamConfig：dream 全局配置

/// dream 一次运行的所有可调参数。
/// 默认值（P8 修正）= **2 步快速路径 + 2 路并发**：
///   - 适用：本地 Ollama 7B（推荐配置）、mock 调试、CI 跑通。
///   - 3 段 CoT 默认关闭，4 路并发默认**不**开。
///   - 想跑 P3 文档里"3 段 + 4 路"那条路径：在 Settings → Dream tab 显式勾选
///     "3-Step CoT" 并把 concurrency 调到 4。
///
///   历史：P3 之前的注释声称"生产推荐 3 段 + 4 路"，但 P3-T2 把默认值改成
///   `useThreeStepCoT: false, concurrency: 2`（决策 T6：用户偏好 fast + 资源友好），
///   注释没跟着改。P8 修文档，但**不改默认值**——保持 Settings → Dream 显式开启路径。
public struct DreamConfig: Sendable {
    public var consolidation: ConsolidationConfig

    public init(consolidation: ConsolidationConfig = ConsolidationConfig()) {
        self.consolidation = consolidation
    }

    /// 快速配置：纯 mock / 调试用（2 步快速路径 + 串行）
    public static let fastDebug = DreamConfig(
        consolidation: ConsolidationConfig(useThreeStepCoT: false, concurrency: 1)
    )
    /// P3-3 评审 §1.2 修复: 生产默认走 3 步 (ConsolidationConfig() 默认), 防幻觉.
    /// 真实 LLM provider (Ollama / OpenAI-compat) 走 3 段 CoT 是默认行为.
    /// 注意: 旧 "productionDefault" 注释 (P3 决策 T6) 说 2 步, P3-3 翻案 — 真生产推荐 3 步.
    public static let productionDefault = DreamConfig()
}

// MARK: - DreamCycle：夜间一次的五步编排器
//
// 串起 Gather → Consolidate → Decay → Persist → Commit，每步失败都能干净回滚。
// git 是事务边界（架构文档第 3 节）：commit 前 vault 是「上一次成功的状态」，
// commit 后是新状态，中间任何一步崩了都用 `GitRunner.discardTrackedChanges()`
// 把工作区拽回 HEAD 状态。
//
// 设计要点：
// 1. 入口点 `runOnce()` 返回 `Result`，上层（CLI / launchd / 单元测试）只关心成功失败
// 2. 失败模式分层：
//    - gather 阶段：抛错 → 已写入的 processed.json 状态回滚（删除文件），不 commit
//    - consolidate/decay/persist 阶段：抛错 → discard tracked changes + 删 .dream/ 写了一半的文件
// 3. 幂等：re-run 时 processed.json 跳过已收文件，不重复消耗 LLM
// 4. 同步 vs 异步：所有阶段 async，但 mock 跑通即可，Ollama 真模型调用也行
public struct DreamCycle {
    public let vaultRoot: URL
    public let llm: LLMProvider
    public let git: GitRunner?
    public let redactor: Redactor
    public let dryRun: Bool
    public let config: DreamConfig

    public init(vaultRoot: URL,
                llm: LLMProvider,
                git: GitRunner? = nil,
                redactor: Redactor = Redactor(),
                dryRun: Bool = false,
                config: DreamConfig = DreamConfig()) {
        self.vaultRoot = vaultRoot
        self.llm = llm
        self.git = git
        self.redactor = redactor
        self.dryRun = dryRun
        self.config = config
    }

    public struct Outcome: Equatable {
        public let gatheredCount: Int
        public let acceptedCount: Int
        public let durableCount: Int
        public let candidateCount: Int
        public let archivedCount: Int
        public let needsReviewCount: Int
        public let reportPath: String?
        public let memoryMdPath: String?
        public let committed: Bool
        /// P8: 本轮脱敏命中统计。空 = 未启用或没命中。
        /// 用途：dream-report 末尾写一段，提示用户"今天 N 条 [REDACTED_XXX]"
        /// 让用户能发现"CN_ID_CARD 误伤长数字串"这类规则问题。
        public let redactionCounts: [String: Int]
        /// P0-1: 矛盾检测预筛统计 + 实际 LLM 调用次数 (dream-report "## Prescreen" 段用)
        public let prescreenStats: PrescreenStats?
        /// P0-3: 假 excerpt 闸门拒收数 (deterministic verification 拒掉的 fabricated draft)
        public let rejectedFabricatedCount: Int
        public var nothingToDo: Bool { gatheredCount == 0 && acceptedCount == 0 }
    }

    /// P0-1: 矛盾检测预筛的统计, 给 dream-report 末尾的 "## Prescreen" 段用
    public struct PrescreenStats: Equatable {
        public let candidatesCount: Int       // 本轮候选数
        public let existingCount: Int         // 现有 durable 数
        public let keptByScreener: Int        // 预筛留下的对数
        public let llmCalls: Int              // 实际调 LLM 的次数
        public let truncated: Int             // 超过 maxPairsPerNight 被截断的对数
        public let maxPairsPerNight: Int      // 配置上限
    }

    public enum DreamError: Error, CustomStringConvertible {
        case gatherFailed(underlying: Error)
        case consolidateFailed(underlying: Error)
        case persistFailed(underlying: Error)
        case commitFailed(underlying: Error)
        case gitNotConfigured
        /// 工作区有"非引擎"的未提交改动，dream 拒绝运行以避免吞掉用户改动。
        /// 用户应先 commit / stash / discard 自己的改动，再跑 dream。
        case userDirtyWorkspace

        public var description: String {
            switch self {
            case .gatherFailed(let e):     return "gather 阶段失败: \(e)"
            case .consolidateFailed(let e): return "consolidate 阶段失败: \(e)"
            case .persistFailed(let e):    return "persist 阶段失败: \(e)"
            case .commitFailed(let e):     return "commit 阶段失败: \(e)"
            case .gitNotConfigured:        return "vault 未配置 git，无法做事务边界"
            case .userDirtyWorkspace:      return "vault 工作区有未提交的非引擎改动（不是 MEMORY.md/.dream/wiki/archive）。请先 commit / stash / discard 自己的改动，再跑 dream。"
            }
        }
    }

    /// 跑一次完整 dream。任何阶段失败都自动回滚已写文件。
    /// 失败时也返回完整 trace（已 gather 但未提交的内容），便于 dream-report 留痕。
    /// - Parameter onStage: 每阶段切换时调用一次（label: gather / consolidate / decay / persist / commit），
    ///   GUI 用此驱动 5 步骤进度条。失败时调用 label: "<stage> failed: <err>"。
    public func runOnce(now: Date = Date(),
                        onStage: ((String) -> Void)? = nil) async throws -> Outcome {
        // — 0. 把 raw/ 挂为只读（架构第 1 节末段） —
        // 这是"原则 1 变成机制"的入口。每次 dream 启动都强压一次，确保
        // 任何在两次 dream 之间被 chmod +w 改动过的文件回到 0o555。
        // 失败（EPERM 等）由 RawReadonlyGuard 内部静默 + stderr，不影响 dream 继续跑。
        try? RawReadonlyGuard.makeReadonly(vaultRoot: vaultRoot)

        // — 0a. 确保 vault 是 git 仓库（事务边界前提）—
        if let git {
            do { try git.initIfNeeded() } catch {
                throw DreamError.gitNotConfigured
            }
            // — 0b. Preflight：工作区有未提交改动？拒绝运行 —
            // 理由：dream 只能 commit 引擎自己写的路径（MEMORY.md / .dream / wiki / archive）。
            // 如果工作区有任何其他未提交改动（用户的 raw、README、配置等），
            // dream 不应该吞掉它们。让用户先 commit 或 stash，再跑 dream。
            do {
                if try git.hasUserDirtyChanges() {
                    throw DreamError.userDirtyWorkspace
                }
            } catch is DreamError {
                throw DreamError.userDirtyWorkspace
            } catch {
                // hasUserDirtyChanges 本身失败 → 保守拒绝
                throw DreamError.userDirtyWorkspace
            }
        }

        // — 1. Gather：raw → 候选集 —
        onStage?("gather")
        let gatherer = Gatherer(vaultRoot: vaultRoot, redactor: redactor)
        let gathered: Gatherer.GatherResult
        do {
            gathered = try gatherer.gather()
            onStage?("gather done: \(gathered.gatheredFiles.count) files")
        } catch {
            onStage?("gather failed: \(error.localizedDescription)")
            throw DreamError.gatherFailed(underlying: error)
        }

        // 早退：没有新源 = 仍跑 Decay 让旧账本被处理，但不调 LLM
        // —— 这里是设计选择：让 dream 每晚都有动作（哪怕只是衰减旧记忆）
        var newAccepted: [Memory] = []
        var mergedLedger = Persister.loadLedger(vaultRoot: vaultRoot)
        // P0-1: 矛盾检测预筛统计 (dream-report ## Prescreen 段)
        var prescreenStats: PrescreenStats? = nil
        // P0-3: 假 excerpt 闸门拒收数 (dream-report ## Fabrication 段)
        var rejectedFabricatedCount: Int = 0

        if !gathered.candidates.isEmpty {
            // — 2. Consolidate：新候选 → 经四道闸的可信教训 —
            // 这里把 Gatherer 已脱敏的候选原样传给 Consolidator；Consolidator 内
            // 还会再脱敏一次（redactBeforeConsolidate 默认 true），是幂等的。
            onStage?("consolidate")
            let consolidator = Consolidator(
                llm: llm,
                config: config.consolidation,
                redactor: redactor,
                sourceContents: gathered.sourceContents  // P0-3: 假 excerpt 闸门
            )
            // 主入口：根据 config.consolidation.useThreeStepCoT 路由
            //   true  → consolidate3Step（生产 LLM 推荐，含 analyze → generate → verify）
            //   false → consolidate（2 步快速路径，mock / 极快模型）
            // 多候选并发上限由 config.consolidation.concurrency 控制。
            do {
                let result = try await consolidator.consolidateSmart(gathered.candidates)
                newAccepted = result.accepted
                rejectedFabricatedCount = result.rejectedFabricated
                onStage?("consolidate done: \(newAccepted.count) accepted (rejected fabricated: \(rejectedFabricatedCount))")
            } catch {
                onStage?("consolidate failed: \(error.localizedDescription)")
                // 失败：撤掉已 gather 的状态（不写 processed 即可，下次会重收）
                throw DreamError.consolidateFailed(underlying: error)
            }

            // — 2b. 矛盾建链：新教训 vs 现有 durable (P0-1: 走预筛) —
            if !newAccepted.isEmpty {
                // 用现有全部 memory 建图 (durable + candidate 都进图, candidate 间连边)
                // 这样预筛的 Adamic-Adar 才能拿到真信号; 否则空图 → 全走 token 预筛
                let graph = KnowledgeGraph(memories: mergedLedger.memories + newAccepted)
                var detector = ContradictionDetector(llm: llm, maxPairsPerNight: 50, graph: graph)
                let dur = mergedLedger.memories.filter { $0.status == .durable }
                if !dur.isEmpty {
                    do {
                        let linked = try await detector.link(candidates: newAccepted, against: dur)
                        newAccepted = linked.candidates
                        // 把改过的现有记忆写回 ledger
                        for (i, updated) in linked.existing.enumerated() {
                            if i < dur.count {
                                let id = dur[i].id
                                if let j = mergedLedger.memories.firstIndex(where: { $0.id == id }) {
                                    mergedLedger.memories[j] = updated
                                }
                            }
                        }
                        // P0-1: 装预筛统计
                        if let pr = detector.lastPrescreenResult {
                            prescreenStats = PrescreenStats(
                                candidatesCount: newAccepted.count,
                                existingCount: dur.count,
                                keptByScreener: pr.totalKeptByScreener,
                                llmCalls: detector.lastLLMCalls,
                                truncated: pr.truncated,
                                maxPairsPerNight: 50
                            )
                        }
                    } catch {
                        onStage?("link failed: \(error.localizedDescription)")
                        // 矛盾检测失败：回滚 — 丢弃新接受的教训（不持久化它们）
                        throw DreamError.consolidateFailed(underlying: error)
                    }
                }
            }

            // — 2c. P3-1: 同质合并 (durable 可达路径) —
            // 新教训 vs 现有 durable 比字符 trigram Jaccard, 命中阈值 (>= 0.5) 则
            // 把新 source 追加进现有 durable, 不新建条目. 这样 2 个 raw 文件分两晚
            // 处理时, ledger 里是 1 条 durable (2 sources) 而非 2 条 candidate.
            if !newAccepted.isEmpty {
                let dur = mergedLedger.memories.filter { $0.status == .durable }
                if !dur.isEmpty {
                    let result = Self.mergeSimilar(
                        newAccepted: newAccepted,
                        existing: mergedLedger.memories
                    )
                    newAccepted = result.newAccepted
                    mergedLedger.memories = result.updatedExisting
                    onStage?("merge: \(result.mergeCount) pairs merged into existing durable")
                }
            }

            // 把新教训合并到 ledger
            for m in newAccepted {
                if !mergedLedger.memories.contains(where: { $0.id == m.id }) {
                    mergedLedger.memories.append(m)
                }
            }

            // P9c-P0-2: 触发点 3 — dream 时新教训引用了同一 raw 源，
            // 对现有 durable/archived 记忆强化 .dreamReference（per-day debounce）
            let referencedFiles = Set(newAccepted.flatMap { $0.sources.map { $0.file } })
            if !referencedFiles.isEmpty {
                let hit = Reinforcer.reinforceBySourceFiles(
                    referencedFiles, vaultRoot: vaultRoot, now: now)
                if !hit.isEmpty {
                    onStage?("reinforce: \(hit.count) existing memories via dreamReference")
                    // 把强化过的记忆再写回 mergedLedger（reinforceBySourceFiles 已落盘，
                    // 这里同步内存避免后续 Persister.persist 用旧值覆盖新值）
                    let ledger = Persister.loadLedger(vaultRoot: vaultRoot)
                    for (i, m) in mergedLedger.memories.enumerated() {
                        if let fresh = ledger.memories.first(where: { $0.id == m.id }) {
                            mergedLedger.memories[i] = fresh
                        }
                    }
                }
            }
        }

        // — 3. Decay：扫所有记忆算 salience 决定动作 —
        onStage?("decay")
        let decayer = Decayer()
        let decayResults = decayer.evaluateAll(mergedLedger)
        onStage?("decay done: \(decayResults.count) memories evaluated")

        // — 4. Persist：写 MEMORY.md、wiki/、ledger.json、dream-report，登记 processed —
        onStage?("persist")
        let persister = Persister(vaultRoot: vaultRoot, git: dryRun ? nil : git)
        let input = Persister.Input(
            ledger: mergedLedger,
            decayResults: decayResults,
            newlyAccepted: newAccepted,
            gatheredFiles: gathered.gatheredFiles,
            redactionCounts: gathered.redactionCounts,  // P8: 让 dream-report 显示命中统计
            prescreenStats: prescreenStats,             // P0-1: 让 dream-report 显示预筛统计
            rejectedFabricatedCount: rejectedFabricatedCount, // P0-3
            now: now
        )

        let outcome: Persister.Outcome
        do {
            outcome = try persister.persist(input)
            let written = outcome.wikiPagesWritten.count + outcome.archivedIDs.count + 1  // +1 for memory.md
            onStage?("persist done: written \(written) files, committed=\(outcome.committed)")
        } catch {
            // 失败回滚：
            // 1) git tracked 的文件（MEMORY.md / .dream/ledger.json / .dream/processed.json /
            //    wiki/ / archive/）由 git.discardTrackedChanges() 还原（最干净）
            // 2) 当次生成的 dream-report-{stamp}.md 由 rollbackDreamArtifacts 清掉
            // 3) 绝不动历史 dream-report-* —— 暴力删目录的风险见 git log 早期修复
            onStage?("persist failed: \(error.localizedDescription)")
            try? rollbackDreamArtifacts(vaultRoot: vaultRoot, currentReportStamp: Self.reportStamp(now: now))
            if let git { try? git.discardTrackedChanges() }
            throw DreamError.persistFailed(underlying: error)
        }

        // — 5. 完成 — Outcome —
        return Outcome(
            gatheredCount: gathered.gatheredFiles.count,
            acceptedCount: newAccepted.count,
            durableCount: outcome.ledger.memories.filter { $0.status == .durable }.count,
            candidateCount: outcome.ledger.memories.filter { $0.status == .candidate }.count,
            archivedCount: outcome.archivedIDs.count,
            needsReviewCount: outcome.needsReviewIDs.count,
            reportPath: outcome.reportPath,
            memoryMdPath: outcome.memoryMdPath,
            committed: outcome.committed,
            redactionCounts: gathered.redactionCounts,
            prescreenStats: prescreenStats,
            rejectedFabricatedCount: rejectedFabricatedCount  // P0-3
        )
    }

    /// 删除 DreamCycle 自己写入的 .dream/ 下的报告/ledger（不算 raw/wiki 那些由 Gatherer/Persister 写的）。
    /// 这是兜底，正常失败回滚路径由 `discardTrackedChanges()` 处理；
    /// 本函数专门清 .dream/reports/ 和 .dream/ledger.json 这种 git 未跟踪的写入。
    /// 仅删除本次 dream 写入的、未被 git 跟踪的文件（保守兜底，绝不删历史报告）。
    /// - ledger.json / processed.json：git tracked，`discardTrackedChanges()` 会还原，
    ///   这里不动，避免误删历史版本
    /// - reports/ 目录：保留，只删当前 stamp 对应的单条报告
    /// - MEMORY.md / wiki/ / archive/：git tracked，由 discardTrackedChanges 还原
    private func rollbackDreamArtifacts(vaultRoot: URL, currentReportStamp: String?) throws {
        let fm = FileManager.default
        // 只清"当次生成的单一报告"（如果能拿到 stamp）
        if let stamp = currentReportStamp {
            let reportURL = vaultRoot.appendingPathComponent(".dream/reports/dream-report-\(stamp).md")
            try? fm.removeItem(at: reportURL)
        }
        // 不删 .dream/reports/ 目录、.dream/ledger.json、.dream/processed.json：
        // 全部交给 git discardTrackedChanges 还原（如果 git 配置了），未 tracked 的留着
        // 也无所谓（下次 dream 会重新覆盖）
    }

    /// 与 Persister 内部的 stamp 格式保持一致 —— 给的同一个 now 必须产出同一个 stamp，
    /// 否则失败回滚时找不到当次的报告。
    static func reportStamp(now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: now)
    }

    // MARK: - P3-1: 同质合并 (durable 可达路径)

    /// 新教训跟现有 memory 比字符 trigram Jaccard 相似度, 命中阈值则合并到现有条目.
    /// - Returns: (更新后的新教训列表, merge 次数)
    ///   - 被合并的"新教训"会被从返回列表移除 (它的 source 进了现有条目)
    ///   - 现有条目的 sources 累加 (去重), lastAccess 更新到 now, status 自动重 classify
    public static func mergeSimilar(newAccepted: [Memory],
                                    existing: [Memory],
                                    now: Date = Date(),
                                    threshold: Double = TextSimilarity.mergeThreshold
    ) -> (newAccepted: [Memory], updatedExisting: [Memory], mergeCount: Int) {
        var remaining = newAccepted
        var updatedExisting = existing
        var mergeCount = 0
        // 预排序 existing: 只跟 status==.durable 比. (candidate 暂不互相合并,
        // 等 §1.1 修复主线 — durable 是 2 源升级目标, candidate 之间合并会变难)
        let durIdx = updatedExisting.enumerated()
            .filter { $0.element.status == .durable }
            .map { $0.offset }
        guard !durIdx.isEmpty else { return (remaining, updatedExisting, 0) }

        var i = 0
        while i < remaining.count {
            let newM = remaining[i]
            var merged = false
            for idx in durIdx {
                let exist = updatedExisting[idx]
                let sim = TextSimilarity.jaccard(newM.text, exist.text)
                if sim >= threshold {
                    // 合并: sources 累加去重, lastAccess 更新, status 重 classify
                    var mergedSources = exist.sources
                    for s in newM.sources {
                        if !mergedSources.contains(where: { $0.file == s.file && $0.line == s.line }) {
                            mergedSources.append(s)
                        }
                    }
                    var updated = exist
                    updated.sources = mergedSources
                    updated.lastAccess = now
                    updated.reinforceCount += 1
                    // 重新 classify (sources 多了, 状态可能升)
                    let distinctSrc = Set(mergedSources.map { $0.file }).count
                    if distinctSrc >= 2 { updated.status = .durable }
                    else if distinctSrc >= 1 { updated.status = .candidate }
                    updatedExisting[idx] = updated
                    mergeCount += 1
                    merged = true
                    break  // 一条新教训只合并一次 (跟最相似的现有条目)
                }
            }
            if merged {
                remaining.remove(at: i)
                // 不增 i, 下一条顶上来
            } else {
                i += 1
            }
        }
        return (remaining, updatedExisting, mergeCount)
    }
}
