import XCTest
@testable import DreamEngine

/// P3-3 评审 §1.2 修复: 3 步 CoT 默认开 + 失败跳过 (而非回退 2 步污染 ledger)
/// 覆盖: 默认值, productionDefault, CounterBox addError, 3 段失败 catch 行为,
/// 真实 LLM 走 3 段 (mock 走 2 步 fast path 区分).
final class ThreeStepDefaultsTests: XCTestCase {

    // MARK: - 默认值

    /// 1. ConsolidationConfig 默认 useThreeStepCoT=true (P3-3 §1.2: 3 步防幻觉)
    func testDefault_useThreeStepCoT_isTrue() {
        let cfg = ConsolidationConfig()
        XCTAssertTrue(cfg.useThreeStepCoT,
                      "P3-3 评审 §1.2: 默认 3 步 (老 false 把原文当教训污染 ledger)")
    }

    /// 2. ConsolidationConfig 默认 fallbackOnThreeStepFailure=false (P3-3 §1.2: 失败跳过不留 ledger 污染)
    func testDefault_fallbackOnThreeStepFailure_isFalse() {
        let cfg = ConsolidationConfig()
        XCTAssertFalse(cfg.fallbackOnThreeStepFailure,
                       "P3-3 评审 §1.2: 3 段失败不回退 2 步, 跳过单条留明晚重试")
    }

    /// 3. productionDefault 3 步 + concurrency=2 (老默认 2 步已翻案)
    func testProductionDefault_threeStepConcurrencyTwo() {
        let cfg = DreamConfig.productionDefault.consolidation
        XCTAssertTrue(cfg.useThreeStepCoT,
                      "productionDefault 3 步 (P3-3 翻案)")
        XCTAssertEqual(cfg.concurrency, 2,
                       "productionDefault concurrency=2 (Ollama 7B 资源友好)")
        XCTAssertFalse(cfg.fallbackOnThreeStepFailure,
                       "productionDefault 不回退 2 步 (防 ledger 污染)")
    }

    /// 4. fastDebug 2 步 + 串行 (mock / debug 用, 不污染测试)
    func testFastDebug_twoStepSerial() {
        let cfg = DreamConfig.fastDebug.consolidation
        XCTAssertFalse(cfg.useThreeStepCoT,
                       "fastDebug 2 步快速路径 (mock / debug)")
        XCTAssertEqual(cfg.concurrency, 1,
                       "fastDebug 串行 (避免并发干扰调试)")
    }

    // MARK: - 3 段失败行为 (用 public consolidateSmart 验证)

    /// 5. 3 段失败 → 跳过单条, 不回退 2 步污染 ledger (useThreeStepCoT=true + fallback=false)
    /// 验证: 给一个 throw-only LLM provider (每次 complete 都抛), 走 3 段 catch, 不污染 ledger
    func testThreeStepFailure_skipsCandidateNotPollutesLedger() async throws {
        // throw-only LLM
        let failingLLM = ThrowingLLMProvider()
        // 给一个有 1 个 candidate 的 raw 文件
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeRaw("a.md", body: "x", in: tmp)

        // P3-3 关键行为: 3 段失败 (concurrency>1 时 TaskGroup catch 吞错) → 跳过该 candidate,
        // 不回退 2 步 (老 fallback=true 会跑 consolidate() 2 步把全文当教训入 ledger).
        // 验证 ledger 保持空 (没教训被入账).
        let config = DreamConfig.productionDefault
        let cycle = DreamCycle(vaultRoot: tmp, llm: failingLLM, git: nil, config: config)
        // 3 段失败 → 走 catch, 不抛, runOnce 正常返回 (acceptedCount=0)
        let outcome = try await cycle.runOnce(now: Date())
        XCTAssertEqual(outcome.acceptedCount, 0,
                       "3 段失败 → 跳过该 candidate → acceptedCount=0 (无教训入账)")
        // ledger 应为空 (关键: 老 fallback=true 会把全文当教训污染 ledger)
        let ledger = Persister.loadLedger(vaultRoot: tmp)
        XCTAssertEqual(ledger.memories.count, 0,
                       "3 段失败 → 跳过该 candidate → ledger 保持空 (老 fallback=true 会把全文当教训污染)")
    }

    /// 6. fastDebug 走 2 步快速路径 (mock 行为: 老 verify keyword)
    /// 验证: MockLLMProvider() (defaultHandler 2 步) + config.fastDebug → 走 2 步, 通过 verify YES
    func testFastDebug_skipsThreeStepPath() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeRaw("a.md", body: "test", in: tmp)

        let cycle = DreamCycle(vaultRoot: tmp, llm: MockLLMProvider(), git: nil, config: .fastDebug)
        let outcome = try await cycle.runOnce(now: Date())
        // useThreeStepCoT=false → consolidate() 2 步 → verify YES → accepted
        XCTAssertEqual(outcome.acceptedCount, 1, "fastDebug 2 步路径走 verify YES → accepted")
    }
}

// MARK: - 测试 fixtures

/// 每次 complete() 都抛错的 LLM provider, 用于测 3 段失败 catch 行为
final class ThrowingLLMProvider: LLMProvider, @unchecked Sendable {
    func complete(system: String, user: String) async throws -> String {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "intentional failure"])
    }
}

// MARK: - 测试 helpers

private func makeTempDir() -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dreamvault-p3-3-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func writeRaw(_ name: String, body: String, in dir: URL) throws {
    let rawDir = dir.appendingPathComponent("raw")
    try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
    let url = rawDir.appendingPathComponent(name)
    let content = """
    ---
    processed: false
    ---
    \(body)
    """
    try content.write(to: url, atomically: true, encoding: .utf8)
}
