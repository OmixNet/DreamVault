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

    /// 把当前 working tree commit 进去（除引擎路径）。每个测试 setup 完后调用。
    /// 测试自己的 raw 文件需要先入库，dream 才有"新源"可收。
    ///
    /// 这里直接调 git 子命令，不走 GitRunner.commitAll —— 后者会 unstage 非引擎路径，
    /// 不适合"用户 commit 自己的 raw"这个语义。
    private func commitWorkingTreeAsUser(message: String) throws {
        let identity = ["-c", "user.name=TestUser", "-c", "user.email=test@example.com"]
        try run(["add", "-A"])
        // 只在有 staged 改动时才 commit
        let status = try runCapture(["status", "--porcelain"])
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try run(identity + ["commit", "-m", message])
    }

    /// 调 git 子命令（捕获 stdout）
    private func runCapture(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", tempDir.path] + args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "TestGit", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// 调 git 子命令（无 stdout）
    private func run(_ args: [String]) throws {
        _ = try runCapture(args)
    }

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
        // 用 raw git 提交（不走 GitRunner.commitAll — 后者会 unstage 非引擎路径，
        // 但 .gitkeep 不是引擎路径，会被 unstage 然后 commit 失败）
        try run(["add", ".gitkeep"])
        try run(["-c", "user.name=TestUser", "-c", "user.email=test@example.com",
                 "commit", "-m", "init"])
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 工具：写 raw 文件

    /// 写 raw 文件并自动 commit（让 raw 文件进入 vault 历史）。
    /// dream 的 preflight 要求工作区干净；测试用的 raw 文件必须先入库。
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
        try commitWorkingTreeAsUser(message: "add raw/\(name)")
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

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git, config: .fastDebug)
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

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git, config: .fastDebug)
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
            // P3-3: 默认 3 步 CoT, analyze + generate + verify 三个 phase.
            // 按 system prompt 关键词判 phase 返相应 JSON.
            if system.contains("事实校验器") { return "YES" }  // verify
            if system.contains("互相矛盾") {
                return user.contains("AppKit") ? "CONFLICT" : "OK"
            }
            if system.contains("分析师") || system.contains("keyEntities") {
                // analyze 阶段: 返合法 JSON
                return #"{"keyEntities":["auto"],"keyConcepts":["auto"],"tensionsWithExisting":[],"recommendedLessonTexts":["mock lesson"],"reasoning":"auto","recommendedKind":"concept"}"#
            }
            if system.contains("提炼员") || system.contains("draft") {
                // generate 阶段: 抠 "原候选文本" 后**第 2 行**当 excerpt (body 原文, P0-3 必过)
                // P3-3: SourceRefValidator 走 normalize.contains. excerpt 必须跟 body 连续 substring.
                // body 整段当 excerpt 必过. sourceFile 抠 user 里 `[raw/xxx.md:NN]` evidence
                // marker 拿真路径 (跟 gatherer 写 mem.sources.first.file 同, 否则
                // consolidate3StepOne line 476 file-mismatch check fail → out=[] → 0 accepted).
                let excerpt: String
                if let markerRange = user.range(of: "原候选文本") {
                    let afterMarker = user[markerRange.upperBound...]
                    let lines = afterMarker.components(separatedBy: "\n")
                    let bodyLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).count >= 5 }) ?? "fallback excerpt"
                    excerpt = String(bodyLine.prefix(200))
                } else {
                    excerpt = "fallback excerpt"
                }
                // 抠真 sourceFile (跟 defaultHandler 走同款)
                let realFile: String
                if let evRange = user.range(of: "[raw/"),
                   let closeRange = user[evRange.upperBound...].range(of: "]") {
                    let filePart = user[evRange.upperBound..<closeRange.lowerBound]
                    if let colonIdx = filePart.firstIndex(of: ":") {
                        realFile = String(filePart[..<colonIdx])
                    } else {
                        realFile = String(filePart)
                    }
                } else {
                    realFile = "raw/test.md"
                }
                return "[{\"text\":\"mock draft\",\"sourceFile\":\"\(realFile)\",\"sourceLine\":1,\"sourceExcerpt\":\"\(excerpt)\"}]"
            }
            return "YES"
        }
        let cycle = DreamCycle(vaultRoot: tempDir, llm: customLLM, git: git, config: .fastDebug)
        let outcome = try await cycle.runOnce(now: now)

        XCTAssertEqual(outcome.gatheredCount, 1)
        XCTAssertEqual(outcome.acceptedCount, 1, "verify 应放行 → 1 个 accepted")
        XCTAssertGreaterThanOrEqual(outcome.needsReviewCount, 1, "矛盾应被记入 needsReview")
    }

    /// 4. 没 git runner 时不崩，只是不 commit
    func testRunOnce_withoutGitRunner_doesNotCrash() async throws {
        _ = try writeRaw("2026-06-11-a.md", body: "无 git 跑通")

        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: nil, config: .fastDebug)
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

    /// 8. P0 致命修复 (缺陷报告 §2.2): vault 有未提交的"非引擎"改动时,
    ///    dream 自动 commit 用户改动 (走 autoCommitUserChanges) 然后继续跑,
    ///    不再抛 userDirtyWorkspace 强迫用户手动 commit.
    ///    用户写完笔记直接 Cmd+Q 不应让 dream 罢工.
    func testRunOnce_userDirtyAutoCommits_thenContinues() async throws {
        // 先跑一次，让引擎产出 ledger/wiki 之类 — 制造干净基线
        _ = try writeRaw("2026-06-11-clean.md", body: "基线 raw")
        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        _ = try await cycle.runOnce(now: now)

        // 用户在工作区放一个"非引擎"的未追踪文件
        let userFile = tempDir.appendingPathComponent("user-draft.md")
        try "用户自己改的文件，应该被 dream 自动 commit".write(to: userFile, atomically: true, encoding: .utf8)

        // 再跑一次 — 不抛错, 走完完整流程
        let outcome = try await cycle.runOnce(now: now)
        XCTAssertNotNil(outcome, "P0 修复: 不应抛 userDirtyWorkspace, 跑完整流程")

        // 用户文件应原样存在
        let userContent = try String(contentsOf: userFile, encoding: .utf8)
        XCTAssertTrue(userContent.contains("用户自己改的文件"))

        // git 历史应含自动 commit + 引擎 commit
        let log = (try? git.run(["log", "--oneline"])) ?? ""
        XCTAssertTrue(log.contains("auto-save"), "git log 应有 [dream auto-save] 自动 commit")
    }

    /// 9. 引擎路径（MEMORY.md / .dream/ / wiki/）的脏改动不算"用户改动"，dream 应该照常运行。
    func testRunOnce_engineDirtyPaths_areAccepted() async throws {
        _ = try writeRaw("2026-06-11-engineDirty.md", body: "测试引擎路径脏改动")
        let cycle = DreamCycle(vaultRoot: tempDir, llm: MockLLMProvider(), git: git)
        _ = try await cycle.runOnce(now: now)

        // 用户改 MEMORY.md（在 dream:begin/end 之外加一段）— 应被识别为引擎路径而非用户改动
        let memoryURL = tempDir.appendingPathComponent("MEMORY.md")
        var content = try String(contentsOf: memoryURL, encoding: .utf8)
        content += "\n\n## 用户的笔记\n\n手写内容，dream 不应该拒绝。\n"
        try content.write(to: memoryURL, atomically: true, encoding: .utf8)

        // 再跑一次 — 应该跑通（因为 dirty 的是引擎路径）。
        // raw/ 在第一轮后被 RawReadonlyGuard chmod 0o555；先 chmod +w 才能再扔文件进来。
        let rawDir = tempDir.appendingPathComponent("raw")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: rawDir.path)
        _ = try writeRaw("2026-06-11-engineDirty2.md", body: "第二轮 raw")
        let outcome = try await cycle.runOnce(now: now)
        XCTAssertEqual(outcome.gatheredCount, 1)
    }
}
