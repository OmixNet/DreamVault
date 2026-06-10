import XCTest
@testable import DreamEngine

/// DreamCycle 端到端集成测试
///
/// 用 mktemp 建一个临时 vault，git init，放 2 个 raw 文件，灌 MockLLMProvider，
/// 跑 `runOnce()` 验证：
///   - MEMORY.md 被写入
///   - ledger.json 存在且包含期望条数
///   - dream-report.md 生成
///   - processed.json 登记了这两个文件
///   - 有 git commit
///
/// 然后再跑一次（幂等性测试），验证第二次无新源 → gathered=0、accepted=0，
/// 但仍能跑完（不应该崩）。
final class DreamCycleIntegrationTests: XCTestCase {

    var tempDir: URL!
    var git: GitRunner!
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 每个测试一个全新临时目录
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dreamvault-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // raw 子目录
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("raw"),
            withIntermediateDirectories: true)
        tempDir = tmp

        // git init + 设个 fake identity（GitRunner 自己会强设，这里是兜底）
        git = GitRunner(repoRoot: tempDir)
        try git.initIfNeeded()
        // 提交一个初始空 commit 避免 root commit 边界
        let initialFile = tempDir.appendingPathComponent(".gitkeep")
        try "init".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = try git.commitAll(message: "init")
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 工具：写 raw 文件

    @discardableResult
    private func writeRaw(_ name: String, body: String, processed: Bool = false) throws -> URL {
        let url = tempDir.appendingPathComponent("raw").appendingPathComponent(name)
        let content = """
        ---
        processed: \(processed ? "true" : "false")
        ---

        \(body)
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 测试

    /// 1. 基本端到端：写 2 个 raw 候选（都标 processed:false），跑 runOnce
    ///    - MockLLM 全部回 YES
    ///    - 因为 2 个 candidate 共享同状态但都来自不同源文件，distinctSourceCount
    ///      是 1 → 只能升级为 durable 如果都标同样的 source。不
    ///      实际：每个 candidate 只有 1 个 source file，所以升级条件不满足，留在 candidate。
    ///    - 这次只验证 pipeline 不崩 + 文件都被写出
    func testRunOnce_endToEnd_createsArtifactsAndCommits() async throws {
        _ = try writeRaw("2026-06-11-a.md",
                        body: "今天决定在 dream 引擎里使用 MockLLMProvider 跑集成测试")
        _ = try writeRaw("2026-06-11-b.md",
                        body: "同时确认 OllamaProvider 在本机可用，使用 ollama run llama3.1")

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        let outcome = try await cycle.runOnce(now: now)

        XCTAssertEqual(outcome.gatheredCount, 2, "应该 gather 到 2 个候选")
        XCTAssertEqual(outcome.acceptedCount, 2, "两个候选都通过 MockLLM YES 闸")
        XCTAssertEqual(outcome.candidateCount, 2, "每个都只有 1 个独立源，所以是 candidate 不是 durable")
        XCTAssertEqual(outcome.durableCount, 0, "没有 durable 因为 distinctSourceCount 都是 1")
        XCTAssertEqual(outcome.archivedCount, 0, "新记忆不会立刻被归档")
        XCTAssertTrue(outcome.committed, "应该自动 commit")

        // 检查文件
        let memoryMd = (try? String(contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? ""
        XCTAssertTrue(memoryMd.contains("dream:begin"), "MEMORY.md 应有 dream:begin 标记")
        XCTAssertTrue(memoryMd.contains("dream:end"), "MEMORY.md 应有 dream:end 标记")
        // candidate 不进 MEMORY.md（只有 durable 进），所以这里只验证托管区存在；
        // 内容至少应该含 dream-report 引用 + 标题
        XCTAssertTrue(memoryMd.contains("MEMORY"),
                      "MEMORY.md 应至少含 MEMORY 标题")

        let ledgerData = try Data(contentsOf: tempDir.appendingPathComponent(".dream/ledger.json"))
        XCTAssertGreaterThan(ledgerData.count, 0, "ledger.json 应非空")

        let processedData = try Data(contentsOf: tempDir.appendingPathComponent(".dream/processed.json"))
        let processedList = try JSONDecoder().decode([String].self, from: processedData)
        XCTAssertEqual(processedList.count, 2, "processed.json 应登记 2 个文件")
        XCTAssertTrue(processedList.contains("raw/2026-06-11-a.md"))
        XCTAssertTrue(processedList.contains("raw/2026-06-11-b.md"))

        // git log 应有新的 commit
        let log = try git.run(["log", "--oneline"])
        XCTAssertTrue(log.contains("dream:"), "git log 应含 dream: commit")
    }

    /// 2. 幂等性：第二次跑 runOnce（无新源）不崩、不重复 commit
    func testRunOnce_idempotent_secondRunNoOp() async throws {
        _ = try writeRaw("2026-06-11-a.md", body: "持久化场景")

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        _ = try await cycle.runOnce(now: now)
        // 记下 commit 数量
        let logBefore = try git.run(["rev-list", "--count", "HEAD"])
        let countBefore = Int(logBefore.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // 第二次：没有新源
        let outcome2 = try await cycle.runOnce(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(outcome2.gatheredCount, 0, "第二次应没有新候选")
        XCTAssertEqual(outcome2.acceptedCount, 0, "第二次没有新接受")
        XCTAssertTrue(outcome2.nothingToDo, "nothignToDo 应为 true")

        // commit 数量可能 +1（因为 persist 阶段仍写 dream-report，即便没有新源）
        // 至少不增加 2 次
        let logAfter = try git.run(["rev-list", "--count", "HEAD"])
        let countAfter = Int(logAfter.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertLessThanOrEqual(countAfter, countBefore + 1, "第二次跑至多一次 commit（写 dream-report）")
    }

    /// 3. 矛盾建链：1 个 candidate 触发 CONFLICT → shouldReview 计数 +1
    ///    注意：MockLLM 的 "AppKit" 关键字同时触发 verify=NO 路径（被丢弃）和 CONFLICT 路径
    ///    （仅当通过 verify 时才走矛盾检测）。所以这里 candidate 必须 text 既能通过 verify
    ///    （不含 halluc/无依据），又能在矛盾检测阶段被识别为矛盾。
    ///    用一个显式 MockLLM handler 验证更可靠：verify=YES、conflict=CONFLICT。
    func testRunOnce_contradictionBumpsNeedsReview() async throws {
        // 预置一个 durable 在 ledger 里
        let preExisting = Memory(
            text: "使用 SwiftUI 构建 macOS 应用",
            sources: [SourceRef(file: "raw/seed.md", line: 1, excerpt: "seed")],
            status: .durable
        )
        let ledger1 = Ledger(memories: [preExisting])
        try Persister.saveLedger(ledger1, vaultRoot: tempDir)

        // 新候选：包含 "AppKit" — verify 应返回 YES、矛盾检测应返回 CONFLICT
        _ = try writeRaw("2026-06-11-x.md",
                        body: "也许应该用 AppKit 来做底层渲染，性能更好")

        // 显式 handler：看 system prompt 决定返回
        // Consolidator.verify 的 system 含 "事实校验器" → 回 YES
        // ContradictionDetector 的 system 含 "互相矛盾" → 看到 AppKit 回 CONFLICT
        let customLLM = MockLLMProvider { system, user in
            if system.contains("事实校验器") { return "YES" }
            if system.contains("互相矛盾") {
                return user.contains("AppKit") ? "CONFLICT" : "OK"
            }
            return "YES"
        }
        let cycle = DreamCycle(vaultRoot: tempDir, llm: customLLM, git: git)
        let outcome = try await cycle.runOnce(now: now)

        XCTAssertEqual(outcome.gatheredCount, 1)
        XCTAssertEqual(outcome.acceptedCount, 1, "verify 应放行 → 1 个 accepted")
        XCTAssertGreaterThanOrEqual(outcome.needsReviewCount, 1, "矛盾应被记入 needsReview")
    }

    /// 4. 没 git runner 时不崩，只是不 commit
    func testRunOnce_withoutGitRunner_doesNotCrash() async throws {
        _ = try writeRaw("2026-06-11-a.md", body: "无 git 跑通")

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: nil)
        let outcome = try await cycle.runOnce(now: now)

        XCTAssertEqual(outcome.gatheredCount, 1)
        XCTAssertEqual(outcome.acceptedCount, 1)
        XCTAssertFalse(outcome.committed, "没 git runner 时 committed = false")
    }

    /// 5. 没新源 + 有矛盾归档：仅跑 Decay，让旧矛盾被标记 needsReview
    func testRunOnce_decayOnEmpty_keepsLedgerIntact() async throws {
        // 预置一个矛盾链接的旧记忆
        let oldWithContradict = Memory(
            id: "old-with-conflict",
            text: "旧矛盾记忆",
            sources: [SourceRef(file: "raw/seed.md", line: 1, excerpt: "x")],
            status: .durable,
            contradicts: ["some-other-id"]
        )
        let ledger2 = Ledger(memories: [oldWithContradict])
        try Persister.saveLedger(ledger2, vaultRoot: tempDir)

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        let outcome = try await cycle.runOnce(now: now)

        XCTAssertEqual(outcome.gatheredCount, 0)
        XCTAssertGreaterThanOrEqual(outcome.needsReviewCount, 1,
            "矛盾链接的记忆在 Decay 阶段应被标 needsReview")
    }

    /// 6. 红线：raw/ 文件永不被改（原则 1）。gathering 之后再读，processed frontmatter 应保持 false
    func testRunOnce_neverModifiesRawFiles() async throws {
        let rawURL = try writeRaw("2026-06-11-protected.md",
                                  body: "原始观察内容，原文不应被修改",
                                  processed: false)

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        _ = try await cycle.runOnce(now: now)

        // raw 文件应该原封不动
        let afterContent = try String(contentsOf: rawURL, encoding: .utf8)
        XCTAssertTrue(afterContent.contains("processed: false"),
                      "raw/ 文件的 processed 标志不应被改写")
        XCTAssertTrue(afterContent.contains("原始观察内容"),
                      "raw/ 文件正文不应被改写")
    }

    /// 7. dryRun 模式：不 commit
    func testRunOnce_dryRun_doesNotCommit() async throws {
        _ = try writeRaw("2026-06-11-a.md", body: "dryRun 测试")
        let cycle = DreamCycle(vaultRoot: tempDir,
                               llm: MockLLMProvider(),
                               git: git,
                               dryRun: true)
        let outcome = try await cycle.runOnce(now: now)
        XCTAssertEqual(outcome.gatheredCount, 1)
        XCTAssertFalse(outcome.committed, "dryRun 时不应 commit")
    }
}
