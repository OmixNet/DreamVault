import Foundation
import DreamEngine

// MARK: - dream CLI
//
// 把 DreamCycle 暴露成可执行命令。所有子命令都通过 ProcessInfo.arguments 解析。
//
// 子命令：
//   dream run     [--vault <path>] [--dry-run]   跑一次 dream（五步）
//   dream report  [--vault <path>]              列出最近 N 份 dream-report 路径
//   dream status  [--vault <path>]              概览 vault 状态（raw/ 候选数 / ledger 条数 / 矛盾数）
//   dream rollback [--vault <path>]             git revert 最近一次 dream commit
//   dream help                                   打印这个帮助
//
// 全局：
//   --vault <path>     vault 根目录（默认 $DREAMVAULT_VAULT 或 $HOME/.dreamvault）
//   --llm <name>       覆盖 LLMFactory：mock / ollama（默认走环境变量 DREAMVAULT_LLM）
//   --verbose          打 detail
//
// 设计要点：
// - 不引第三方依赖，纯 stdlib（ArgumentParser 那类 fancy 库先不用）
// - 所有子命令共享 main 一处入口，switch dispatch
// - 退出码：0=成功、1=用户错误（路径/参数）、2=dream 阶段失败、3=git 失败
@main
struct DreamCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())  // 去掉 argv[0]
        do {
            let code = try await dispatch(args)
            Foundation.exit(code)
        } catch let err as DreamCycle.DreamError {
            FileHandle.standardError.write(Data("dream: \(err)\n".utf8))
            Foundation.exit(2)
        } catch {
            FileHandle.standardError.write(Data("dream: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
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
        let llm = opts.llmProvider()
        let git = GitRunner(repoRoot: vault)
        let cycle = DreamCycle(vaultRoot: vault, llm: llm, git: git, dryRun: dryRun)
        do {
            let outcome = try await cycle.runOnce()
            if opts.verbose {
                FileHandle.standardError.write(Data("dream run verbose report:\n".utf8))
                FileHandle.standardError.write(Data(formatOutcome(outcome).utf8))
            }
            print(humanSummary(outcome))
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
                guard let content = try? String(contentsOf: f, encoding: .utf8) else { return false }
                return content.contains("processed: false")
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

    // MARK: - help

    static func printHelp() {
        let help = """
        dream — DreamVault 夜间记忆整理 CLI

        用法:
          dream run     [--vault <path>] [--dry-run]
          dream report  [--vault <path>] [--last N]
          dream status  [--vault <path>]
          dream rollback [--vault <path>]
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
          dream run --vault ~/MyVault --llm ollama
          dream report --last 3
          dream status
          dream rollback
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
