import XCTest
@testable import DreamEngine

/// P8: 预算必须真实接进 LLM 调用。
/// 之前 BudgetManager 只有 test 里 recordCall，生产代码 0 处调，
/// 整个"预算"功能实质是"检查器"，调用次数不增加。
/// 修法：BudgetedLLMProvider wrapper 透明包裹任何 LLMProvider，
///   - 进入时 canProceedFn() 阻断超额
///   - 退出时 recordCallFn() 记录估算 token
@MainActor
final class BudgetedLLMProviderTests: XCTestCase {

    private func makeBudgetVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p8-budget-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBudgetManager(maxPerDay: Int, monthlyUSD: Double) -> BudgetManager {
        let vault = makeBudgetVault()
        let cfg = ResolvedDreamRuntimeConfig.ResolvedBudget(
            maxCallsPerDay: maxPerDay,
            monthlyBudgetUSD: monthlyUSD,
            onExceed: .skip
        )
        // 把"unknown"也放进 priceTable，让预算检查能算预估成本
        return BudgetManager(config: cfg, vaultRoot: vault, priceTable: [
            "test-model": .init(inputPer1k: 0, outputPer1k: 0.001),
            "unknown": .init(inputPer1k: 0, outputPer1k: 0.001)
        ])
    }

    /// 构造一个 stub 形式的 BudgetedLLMProvider（test 不需要真 MainActor 跨线程）
    private func makeWrapped(_ inner: any LLMProvider,
                              providerName: String,
                              bm: BudgetManager) -> (BudgetedLLMProvider, BudgetManager) {
        let canProceedFn: @Sendable (_ estOutTok: Int, _ modelHint: String) async -> Bool = { estOutTok, modelHint in
            await MainActor.run { bm.canProceed(estimatedOutputTokens: estOutTok, modelHint: modelHint) }
        }
        let recordCallFn: @Sendable (String, String, Int, Int) async -> Void = { p, m, i, o in
            await MainActor.run {
                bm.recordCall(provider: p, model: m, inputTokens: i, outputTokens: o)
            }
        }
        return (BudgetedLLMProvider(
            wrapping: inner,
            providerName: providerName,
            canProceedFn: canProceedFn,
            recordCallFn: recordCallFn
        ), bm)
    }

    // MARK: - 正常路径：每次调用都 recordCall

    func testNormalCall_recordsOneCall() async throws {
        let bm = makeBudgetManager(maxPerDay: 10, monthlyUSD: 0)
        let inner = MockLLMProvider(handler: { _, _ in "hello back" })
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)

        let r = try await wrapped.complete(system: "sys", user: "user")
        XCTAssertEqual(r, "hello back")
        XCTAssertEqual(bm.todayCount, 1, "调用 1 次之后 todayCount 应该是 1")
    }

    func testMultipleCalls_accumulate() async throws {
        let bm = makeBudgetManager(maxPerDay: 10, monthlyUSD: 0)
        let inner = MockLLMProvider(handler: { _, _ in "ok" })
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)

        for _ in 0..<5 {
            _ = try await wrapped.complete(system: "s", user: "u")
        }
        XCTAssertEqual(bm.todayCount, 5, "5 次调用之后 todayCount 应该是 5")
    }

    // MARK: - 超额阻断

    func testDailyCapBlocksExcessCalls() async throws {
        let bm = makeBudgetManager(maxPerDay: 2, monthlyUSD: 0)
        let inner = MockLLMProvider(handler: { _, _ in "ok" })
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)

        // 2 次成功
        _ = try await wrapped.complete(system: "s", user: "u")
        _ = try await wrapped.complete(system: "s", user: "u")
        // 第 3 次必须抛
        do {
            _ = try await wrapped.complete(system: "s", user: "u")
            XCTFail("第 3 次应该抛 BudgetExceededError")
        } catch let e as BudgetedLLMProvider.BudgetExceededError {
            XCTAssertTrue(e.reason.contains("Daily"), "reason 应该提到 daily")
        } catch {
            XCTFail("抛错类型不对: \(error)")
        }
    }

    func testMonthlyBudgetBlocks() async throws {
        // 设极小月度预算 + 调大返回内容，让估算的 output token cost 一定超
        let bm = makeBudgetManager(maxPerDay: 0, monthlyUSD: 0.000001)
        let inner = MockLLMProvider(handler: { _, _ in String(repeating: "x", count: 8000) })
        // 8000 char / 4 chars-per-token = 2000 output tokens
        // Wrapper 内部 estOutTok = (sys+user)/4*1.5 ≈ 3 tokens（system "s" + user "u" = 2 chars）
        // → estCost = 3/1000 * 0.001 = 0.000003
        // 实际调用 2000 tokens → 0.002 美元
        // canProceed 的预估仅看 estimatedOutputTokens；这是预测的盲区。
        // 实际生产中应改用 wrapper 内部已知的 actualOutputTokens 走 canProceed，但那是 recordCall 之后。
        // 这里改为：先 recordCall（cost 涨到 0.002），第二次调用时 monthCost = 0.002 > 0.000001 → 抛
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)
        _ = try? await wrapped.complete(system: "s", user: "u")
        do {
            _ = try await wrapped.complete(system: "s", user: "u")
            XCTFail("第二次调用时 monthCost > monthlyBudgetUSD，应该抛错")
        } catch let e as BudgetedLLMProvider.BudgetExceededError {
            XCTAssertTrue(e.reason.contains("monthly") || e.reason.contains("Daily"),
                          "reason 应该说 daily/monthly；实际: \(e.reason)")
        } catch {
            XCTFail("类型错: \(error)")
        }
    }

    // MARK: - Token 估算

    func testTokenEstimation_usesCharsPerToken() async throws {
        let bm = makeBudgetManager(maxPerDay: 10, monthlyUSD: 0)
        let inner = MockLLMProvider(handler: { _, _ in "this is the response" })
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)

        _ = try await wrapped.complete(system: "system", user: "user")
        let last = bm.lastCall
        XCTAssertNotNil(last)
        let expectInput = ("system".count + "user".count) / 4  // 10/4 = 2
        XCTAssertEqual(last?.inputTokens, expectInput, "input token 估算 = char/4")
        let expectOutput = "this is the response".count / 4  // 20/4 = 5
        XCTAssertEqual(last?.outputTokens, expectOutput, "output token 估算 = char/4")
    }

    // MARK: - Sendable 跨 Task

    func testBudgetedProvider_isSendableInAsyncContext() async throws {
        let bm = makeBudgetManager(maxPerDay: 10, monthlyUSD: 0)
        let inner = MockLLMProvider(handler: { _, _ in "ok" })
        let (wrapped, _) = makeWrapped(inner, providerName: "mock", bm: bm)
        // 跨 Task 用 → 如果不是 Sendable 会编译错误
        let result = try await Task {
            try await wrapped.complete(system: "s", user: "u")
        }.value
        XCTAssertEqual(result, "ok")
    }
}
