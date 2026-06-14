import XCTest
@testable import DreamEngine
import AppKit

/// P3 production-readiness 端到端回归
/// - DreamSettings UserDefaults 持久化
/// - ConflictResolution 不依赖 ObservableObject（已在 dream target 测试）
/// - VaultSearcher mdfind 包装（用临时 vault 装 1 个 .md，调 search 不要求命中）
@MainActor
final class ProductionReadinessTests: XCTestCase {

    // MARK: - DreamSettings

    func testDreamSettings_roundTripThroughUserDefaults() {
        let original = DreamSettings(
            vaultPath: "/tmp/test-vault",
            llmChoice: .ollama,
            ollamaBaseURL: "http://example:9999",
            ollamaModel: "qwen2.5",
            useThreeStepCoT: true,
            consolidationConcurrency: 3,
            nightlyDreamEnabled: true
        )
        original.save()
        defer {
            // 清理 UserDefaults
            for k in ["DreamVault.vaultPath", "DreamVault.llmChoice",
                      "DreamVault.ollamaBaseURL", "DreamVault.ollamaModel",
                      "DreamVault.useThreeStepCoT", "DreamVault.consolidationConcurrency",
                      "DreamVault.nightlyDreamEnabled"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        let loaded = DreamSettings.load()
        XCTAssertEqual(loaded.vaultPath, "/tmp/test-vault")
        XCTAssertEqual(loaded.llmChoice, .ollama)
        XCTAssertEqual(loaded.ollamaBaseURL, "http://example:9999")
        XCTAssertEqual(loaded.ollamaModel, "qwen2.5")
        XCTAssertTrue(loaded.useThreeStepCoT)
        XCTAssertEqual(loaded.consolidationConcurrency, 3)
        XCTAssertTrue(loaded.nightlyDreamEnabled)
    }

    func testDreamSettings_concurrencyClampedToValidRange() {
        // cap [1, 4] — 用户填 100 应当被夹
        let s = DreamSettings(
            vaultPath: "/x", llmChoice: .mock, ollamaBaseURL: "x", ollamaModel: "x",
            useThreeStepCoT: false, consolidationConcurrency: 100, nightlyDreamEnabled: false
        )
        XCTAssertEqual(s.consolidationConcurrency, 4, "应被 cap 到 4")
        let s2 = DreamSettings(
            vaultPath: "/x", llmChoice: .mock, ollamaBaseURL: "x", ollamaModel: "x",
            useThreeStepCoT: false, consolidationConcurrency: 0, nightlyDreamEnabled: false
        )
        XCTAssertEqual(s2.consolidationConcurrency, 1, "应被夹到至少 1")
    }

    func testDreamSettings_makesExpectedLLM() {
        let s = DreamSettings.default
        let p = s.makeLLMProvider()
        XCTAssertNotNil(p, "default 应能造出 provider")
    }

    func testDreamSettings_consolidationConfig_passesFlags() {
        let s = DreamSettings(
            vaultPath: "/x", llmChoice: .mock, ollamaBaseURL: "x", ollamaModel: "x",
            useThreeStepCoT: true, consolidationConcurrency: 3, nightlyDreamEnabled: false
        )
        let cfg = s.consolidationConfig()
        XCTAssertTrue(cfg.useThreeStepCoT, "3-Step 标志应透传")
        XCTAssertEqual(cfg.concurrency, 3, "concurrency 应透传")
    }

    // MARK: - VaultSearcher (smoke test, 不要求 mdfind 命中)

    func testVaultSearcher_emptyQuery_noResults() async {
        let searcher = VaultSearcher()
        await MainActor.run {
            searcher.query = ""
            searcher.search(vaultRoot: URL(fileURLWithPath: "/tmp"))
        }
        // 100ms 后查 results 应仍为空
        try? await Task.sleep(nanoseconds: 100_000_000)
        await MainActor.run {
            XCTAssertTrue(searcher.results.isEmpty, "空 query 不应返回结果")
        }
    }

    // MARK: - T2 重试: 不 mock LLMProvider，但能验 wrapper 存在

    func testConsolidationConfig_concurrencyCapTo4() {
        // 验证 Consolidator.consolidate3Step 的 cap 行为
        // 5 个并发 → 应当被夹到 4
        let cfg = ConsolidationConfig(concurrency: 5)
        XCTAssertEqual(cfg.concurrency, 4, "ConsolidationConfig init 应 cap 5→4")

        // 0 → 1
        let cfg0 = ConsolidationConfig(concurrency: 0)
        XCTAssertEqual(cfg0.concurrency, 1, "concurrency 0 应被夹到 1")
    }

    // MARK: - T5 shouldProcessRaw 三分支

    func testShouldProcessRaw_threeBranches() {
        // 显式 false
        let c1 = "---\nprocessed: false\n---\nbody"
        XCTAssertTrue(Gatherer.shouldProcessRaw(content: c1))
        // 显式 true
        let c2 = "---\nprocessed: true\n---\nbody"
        XCTAssertFalse(Gatherer.shouldProcessRaw(content: c2))
        // 无 frontmatter → 保守按未处理
        let c3 = "no frontmatter here"
        XCTAssertTrue(Gatherer.shouldProcessRaw(content: c3))
        // 显式 false 大小写
        let c4 = "---\nprocessed: FALSE\n---\nbody"
        XCTAssertTrue(Gatherer.shouldProcessRaw(content: c4))
    }
}
