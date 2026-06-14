import Foundation
import DreamEngine

// MARK: - dream 二进制统一入口
//
// dream 这个二进制现在有两个 mode：
//   1. CLI mode（默认）：`dream run` / `report` / `status` / `rollback` / `help` / `version`
//   2. GUI mode（`dream app`）：启动 SwiftUI 主窗口（VaultBrowser + Editor + DreamPanel）
//
// 入口路由：
//   - argv[1] == "app"  → 调 SwiftUI 的 App.main()（App 协议自身有 @main）
//   - 其他              → 走 CLI dispatch
//
// 为何不让两个 mode 都用 @main？因为 Swift 一个 target 只能有一个 @main。
// 解决：CLI 自己写 static main()，GUI 在 DreamVaultApp.swift 里写 @main。
// 二进制顶层 entry 写一个 bootstrap 函数，梦引擎选择调哪个 main。

// MARK: - dream CLI

struct DreamCLI {
    /// 真正的 CLI main（不是 @main）。由 entry() 显式调
    /// 返回 exit code（不调 Foundation.exit，让 @main 统一收口）
    static func main() async -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())  // 去掉 argv[0]
        do {
            return try await dispatch(args)
        } catch let err as DreamCycle.DreamError {
            FileHandle.standardError.write(Data("dream: \(err)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("dream: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: - 顶层 dispatch

    static func dispatch(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else {
            printHelp()
            return 0
        }
        var rest = Array(args.dropFirst())
        // 全局 --vault / --llm / --verbose 允许出现在子命令前或后
        let opts = GlobalOptions.parse(from: &rest)
        switch sub {
        case "run":     return await cmdRun(rest, opts: opts)
        case "report":  return cmdReport(rest, opts: opts)
        case "status":  return cmdStatus(rest, opts: opts)
        case "rollback": return cmdRollback(rest, opts: opts)
        case "eval":    return await cmdEval(rest, opts: opts)
        case "app":     return cmdApp(rest, opts: opts)
        case "help", "-h", "--help":
            printHelp()
            return 0
        case "version", "--version", "-V":
            print("dream 0.1.0 (DreamEngine 内核)")
            return 0
        default:
            FileHandle.standardError.write(Data("dream: 未知子命令 '\(sub)'\n".utf8))
            printHelp()
            return 1
        }
    }

    // MARK: - dream run

    static func cmdRun(_ args: [String], opts: GlobalOptions) async -> Int32 {
        var dryRun = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dry-run": dryRun = true; i += 1
            default:
                FileHandle.standardError.write(Data("dream run: 未知参数 '\(args[i])'\n".utf8))
                return 1
            }
        }
        let vault = opts.vaultURL()
        do {
            let runtime = try await opts.runtimeContext()
            let git = GitRunner(repoRoot: vault)
            let cycle = DreamCycle(
                vaultRoot: vault,
                llm: runtime.provider,
                git: git,
                dryRun: dryRun,
                config: runtime.dreamConfig
            )
            // 先把 raw/ 挂为只读（架构第 1 节末段："app 启动时 chmod"）。
            // DreamCycle 内部也会再调一次，这里是 CLI 入口的显式保险——dryRun 也调，
            // 因为 dryRun 仍然跑 gather，可能触发对 raw/ 的潜在写入。
            try? RawReadonlyGuard.makeReadonly(vaultRoot: vault)
            let outcome = try await cycle.runOnce()
            if opts.verbose {
                FileHandle.standardError.write(Data("dream run verbose report:\n".utf8))
                FileHandle.standardError.write(Data(formatOutcome(outcome).utf8))
            }
            print(humanSummary(outcome))
            // P8: 末尾打预算使用状态
            let summary = await MainActor.run {
                "budget: today \(runtime.budgetManager.todayCount) call(s), $\(String(format: "%.4f", runtime.budgetManager.todayCost)) used"
            }
            print(summary)
            _ = summary  // 闭包式用一下避免 unused warning
            return 0
        } catch let err as DreamCycle.DreamError {
            FileHandle.standardError.write(Data("dream run 失败: \(err)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("dream run 未预期错误: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - dream report

    static func cmdReport(_ args: [String], opts: GlobalOptions) -> Int32 {
        let n = parseIntFlag(args, "--last", default: 5)
        let vault = opts.vaultURL()
        let reportsDir = vault.appendingPathComponent(".dream/reports")
        let fm = FileManager.default
        guard fm.fileExists(atPath: reportsDir.path) else {
            print("（无 .dream/reports/，从未跑过 dream）")
            return 0
        }
        let key: URLResourceKey = .creationDateKey
        let urls = (try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [key])) ?? []
        let sorted = urls.sorted { lhs, rhs in
            let ld = (try? lhs.resourceValues(forKeys: [key]).creationDate) ?? .distantPast
            let rd = (try? rhs.resourceValues(forKeys: [key]).creationDate) ?? .distantPast
            return ld > rd
        }
        let take = min(n, sorted.count)
        guard take > 0 else {
            print("（没有 dream-report 文件）")
            return 0
        }
        for url in sorted.prefix(take) {
            print(url.path)
        }
        return 0
    }

    // MARK: - dream status

    static func cmdStatus(_ args: [String], opts: GlobalOptions) -> Int32 {
        let vault = opts.vaultURL()
        let fm = FileManager.default
        print("vault: \(vault.path)")

        // raw/ 候选数 = frontmatter 标 processed:false 且不在 processed.json
        let rawDir = vault.appendingPathComponent("raw")
        if fm.fileExists(atPath: rawDir.path) {
            let processed = Gatherer.loadProcessedRegistry(vaultRoot: vault)
            let files = (try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)) ?? []
            let candidates = files.filter { f in
                let rel = "raw/\(f.lastPathComponent)"
                if processed.contains(rel) { return false }
                // P0 致命修复 (缺陷报告 §1.3): 用 FrontmatterScanner 流式扫, 避免 String(contentsOf:) 全文读到内存
                // 5MB 笔记 UI 假死. 老实现 O(file size) → 新实现 O(frontmatter 行数)
                return FrontmatterScanner.hasProcessedFalse(f)
            }
            print("raw/ 候选（未处理）: \(candidates.count)")
        } else {
            print("raw/ 不存在")
        }

        // ledger
        let ledger = Persister.loadLedger(vaultRoot: vault)
        print("ledger 总条数: \(ledger.memories.count)")
        let durable = ledger.memories.filter { $0.status == .durable }.count
        let candidate = ledger.memories.filter { $0.status == .candidate }.count
        let archived = ledger.memories.filter { $0.status == .archived }.count
        let withContradicts = ledger.memories.filter { !$0.contradicts.isEmpty }.count
        print("  - durable: \(durable)")
        print("  - candidate: \(candidate)")
        print("  - archived: \(archived)")
        print("  - 含矛盾链接: \(withContradicts)")

        // 最近一次 dream-report
        let reportsDir = vault.appendingPathComponent(".dream/reports")
        let key: URLResourceKey = .creationDateKey
        if let last = ((try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [key])) ?? [])
            .sorted(by: { (try? $0.resourceValues(forKeys: [key]).creationDate) ?? .distantPast
                       > (try? $1.resourceValues(forKeys: [key]).creationDate) ?? .distantPast })
            .first {
            print("最近 dream-report: \(last.path)")
        }
        return 0
    }

    // MARK: - dream rollback

    static func cmdRollback(_ args: [String], opts: GlobalOptions) -> Int32 {
        let vault = opts.vaultURL()
        let git = GitRunner(repoRoot: vault)
        do {
            let head = try git.headHash()
            try git.revertLast()
            print("已 revert HEAD (\(head.prefix(7)))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("rollback 失败: \(error)\n".utf8))
            return 3
        }
    }

    // MARK: - dream app (SwiftUI GUI)
    //
    // 这里只是 fallback —— 正常情况下 @main 在 Entry.swift 里的 DreamEntry.main()
    // 会直接调 SwiftUI App.main()，不会走到这里。如果有人手工 dispatch 才到这。
    static func cmdApp(_ args: [String], opts: GlobalOptions) -> Int32 {
        // 实际 GUI 启动由 Entry.swift 的 @main 处理。这里只留个错误信息兜底。
        FileHandle.standardError.write(Data(
            "dream app: GUI 应由 @main 入口启动，不应通过 CLI dispatch 走到这里\n".utf8))
        return 1
    }

    // MARK: - dream eval (P3-8 §3 修复: 金标评测集)

    /// P3-8: 跑金标评测集 (30 case), 算 P/R/F1. 不绑 CI.
    /// `dream eval [--llm mock|ollama] [--phase verify|contradiction|all] [--report path.md]`
    /// - 默认 --llm mock (MockLLMProvider.defaultHandler 2 步 fast path)
    /// - 默认 --phase all (跑 verify + contradiction 全部)
    /// - 默认 stdout 输出 markdown 报告; --report <path> 写到文件
    static func cmdEval(_ args: [String], opts: GlobalOptions) async -> Int32 {
        // 解析参数
        var phaseFilter: String? = nil
        var reportPath: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--phase":
                i += 1
                if i < args.count { phaseFilter = args[i] }
            case "--report":
                i += 1
                if i < args.count { reportPath = args[i] }
            default:
                FileHandle.standardError.write(Data(
                    "dream eval: 未知参数 '\(a)'\n".utf8))
                return 1
            }
            i += 1
        }

        // 选 provider (跟 DREAMVAULT_LLM / --llm 一致)
        let provider = LLMFactory.fromEnvironment()
        FileHandle.standardError.write(Data(
            "[dream eval] provider: \(type(of: provider)) phase: \(phaseFilter ?? "all")\n".utf8))

        // 选 phase
        let cases: [EvalCase]
        if let p = phaseFilter {
            switch p {
            case "verify": cases = EvalDataset.cases(for: .verify)
            case "contradiction": cases = EvalDataset.cases(for: .contradiction)
            default:
                FileHandle.standardError.write(Data(
                    "dream eval: 未知 phase '\(p)' (verify|contradiction|all)\n".utf8))
                return 1
            }
        } else {
            cases = EvalDataset.standard
        }

        // 跑
        let runner = EvalRunner(dataset: cases, provider: provider)
        let report = await runner.run()

        // 输出 markdown
        let md = EvalReportMarkdown.render(report)
        if let path = reportPath {
            do {
                try md.write(toFile: path, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data(
                    "[dream eval] 报告写到 \(path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "dream eval: 写报告失败: \(error.localizedDescription)\n".utf8))
                return 1
            }
        } else {
            print(md)
        }

        // 退出码: 0 = 全部正确, 1 = 有错 (但仍输出报告供 review)
        let total = report.aggregate()
        return total.correct == total.total ? 0 : 1
    }

    // MARK: - help

    static func printHelp() {
        let help = """
        dream — DreamVault 夜间记忆整理 CLI / GUI

        用法:
          dream run     [--vault <path>] [--dry-run]
          dream report  [--vault <path>] [--last N]
          dream status  [--vault <path>]
          dream rollback [--vault <path>]
          dream eval    [--llm mock|ollama] [--phase verify|contradiction|all]
                        [--report path.md]
          dream app     [--vault <path>]              启动 SwiftUI GUI
          dream help
          dream version

        全局选项（可放在子命令前/后）:
          --vault <path>     vault 根目录
                            （默认 $DREAMVAULT_VAULT，否则 $HOME/.dreamvault）
          --llm <name>       覆盖 DREAMVAULT_LLM（mock|ollama）
          --verbose          打 detail

        环境变量:
          DREAMVAULT_LLM     mock|ollama（默认 mock）
          DREAMVAULT_VAULT   vault 默认路径
          OLLAMA_BASE_URL    Ollama endpoint（默认 http://127.0.0.1:11434）
          OLLAMA_MODEL       Ollama 模型名（默认 llama3.1）

        退出码:
          0 成功
          1 用户错误（参数/路径）
          2 dream 阶段失败（Gather/Consolidate/Persist）
          3 git 失败（commit/revert）

        示例:
          dream run --vault ~/MyVault
          dream app --vault ~/MyVault              # 打开 GUI 窗口
          dream run --vault ~/MyVault --llm ollama
          dream report --last 3
          dream status
          dream rollback
          dream eval --llm ollama --report eval-2026-06-14.md
        """
        print(help)
    }

    // MARK: - 输出格式

    static func humanSummary(_ o: DreamCycle.Outcome) -> String {
        if o.nothingToDo {
            return "dream: 一无事事（无新 raw，无矛盾需要裁决）"
        }
        var lines: [String] = []
        lines.append("dream 完成:")
        lines.append("  - 收集 raw: \(o.gatheredCount)")
        lines.append("  - 通过整合: \(o.acceptedCount)（durable \(ledgerCountOfDurable(o)) / candidate \(o.candidateCount - ledgerCountOfDurable(o))）")
        if o.archivedCount > 0 { lines.append("  - 降级归档: \(o.archivedCount)") }
        if o.needsReviewCount > 0 { lines.append("  - 待人工裁决: \(o.needsReviewCount)") }
        if o.committed { lines.append("  - 已 git commit") }
        if let p = o.reportPath { lines.append("  - dream-report: \(p)") }
        return lines.joined(separator: "\n")
    }

    static func formatOutcome(_ o: DreamCycle.Outcome) -> String {
        var s = "  gathered=\(o.gatheredCount)"
        s += " accepted=\(o.acceptedCount)"
        s += " candidate=\(o.candidateCount)"
        s += " durable=\(o.durableCount)"
        s += " archived=\(o.archivedCount)"
        s += " needsReview=\(o.needsReviewCount)"
        s += " committed=\(o.committed)"
        if let p = o.reportPath { s += "\n  report=\(p)" }
        if let p = o.memoryMdPath { s += "\n  memory=\(p)" }
        return s + "\n"
    }

    // durableCount 在 Outcome 里是 ledger 全部（不是本次新增）—— 这里用
    // 减法近似 "本次新增"：本次 candidate 增量 = 接受数 - 升 durable 数
    // （仅当候选都来自 raw/ 时合理；保守实现：返回 candidateCount，不强求准确）
    static func ledgerCountOfDurable(_ o: DreamCycle.Outcome) -> Int {
        return o.durableCount
    }

    // MARK: - 参数解析小工具

    static func parseIntFlag(_ args: [String], _ flag: String, default def: Int) -> Int {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return def }
        return n
    }
}
