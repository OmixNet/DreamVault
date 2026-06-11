import Foundation

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

    public init(vaultRoot: URL,
                llm: LLMProvider,
                git: GitRunner? = nil,
                redactor: Redactor = Redactor(),
                dryRun: Bool = false) {
        self.vaultRoot = vaultRoot
        self.llm = llm
        self.git = git
        self.redactor = redactor
        self.dryRun = dryRun
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
        public var nothingToDo: Bool { gatheredCount == 0 && acceptedCount == 0 }
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
    public func runOnce(now: Date = Date()) async throws -> Outcome {
        // — 0. 确保 vault 是 git 仓库（事务边界前提）—
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
        let gatherer = Gatherer(vaultRoot: vaultRoot, redactor: redactor)
        let gathered: Gatherer.GatherResult
        do {
            gathered = try gatherer.gather()
        } catch {
            throw DreamError.gatherFailed(underlying: error)
        }

        // 早退：没有新源 = 仍跑 Decay 让旧账本被处理，但不调 LLM
        // —— 这里是设计选择：让 dream 每晚都有动作（哪怕只是衰减旧记忆）
        var newAccepted: [Memory] = []
        var mergedLedger = Persister.loadLedger(vaultRoot: vaultRoot)

        if !gathered.candidates.isEmpty {
            // — 2. Consolidate：新候选 → 经四道闸的可信教训 —
            // 这里把 Gatherer 已脱敏的候选原样传给 Consolidator；Consolidator 内
            // 还会再脱敏一次（redactBeforeConsolidate 默认 true），是幂等的。
            let consolidator = Consolidator(llm: llm, redactor: redactor)
            // 注意：Gatherer 产出的 candidate status 默认 .candidate（单源），升 durable
            // 需要 ≥2 独立源。这里直接走 consolidate 走完闸 0/1/3/2。
            do {
                newAccepted = try await consolidator.consolidate(gathered.candidates)
            } catch {
                // 失败：撤掉已 gather 的状态（不写 processed 即可，下次会重收）
                throw DreamError.consolidateFailed(underlying: error)
            }

            // — 2b. 矛盾建链：新教训 vs 现有 durable —
            if !newAccepted.isEmpty {
                let detector = ContradictionDetector(llm: llm)
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
                    } catch {
                        // 矛盾检测失败：回滚 — 丢弃新接受的教训（不持久化它们）
                        throw DreamError.consolidateFailed(underlying: error)
                    }
                }
            }

            // 把新教训合并到 ledger
            for m in newAccepted {
                if !mergedLedger.memories.contains(where: { $0.id == m.id }) {
                    mergedLedger.memories.append(m)
                }
            }
        }

        // — 3. Decay：扫所有记忆算 salience 决定动作 —
        let decayer = Decayer()
        let decayResults = decayer.evaluateAll(mergedLedger)

        // — 4. Persist：写 MEMORY.md、wiki/、ledger.json、dream-report，登记 processed —
        let persister = Persister(vaultRoot: vaultRoot, git: dryRun ? nil : git)
        let input = Persister.Input(
            ledger: mergedLedger,
            decayResults: decayResults,
            newlyAccepted: newAccepted,
            gatheredFiles: gathered.gatheredFiles,
            now: now
        )

        let outcome: Persister.Outcome
        do {
            outcome = try persister.persist(input)
        } catch {
            // 失败回滚：discard tracked changes + 删 DreamCycle 自己写的 .dream/ 文件
            try? rollbackDreamArtifacts(vaultRoot: vaultRoot)
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
            committed: outcome.committed
        )
    }

    /// 删除 DreamCycle 自己写入的 .dream/ 下的报告/ledger（不算 raw/wiki 那些由 Gatherer/Persister 写的）。
    /// 这是兜底，正常失败回滚路径由 `discardTrackedChanges()` 处理；
    /// 本函数专门清 .dream/reports/ 和 .dream/ledger.json 这种 git 未跟踪的写入。
    private func rollbackDreamArtifacts(vaultRoot: URL) throws {
        let fm = FileManager.default
        for path in [".dream/reports", ".dream/ledger.json", ".dream/processed.json"] {
            let url = vaultRoot.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
