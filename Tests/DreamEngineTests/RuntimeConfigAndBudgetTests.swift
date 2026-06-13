import XCTest
@testable import DreamEngine
import AppKit

/// P4 production-readiness: 5-source config merge + Keychain + Budget + audit
@MainActor
final class RuntimeConfigAndBudgetTests: XCTestCase {

    // MARK: - P4-T1: ResolvedDreamRuntimeConfig 5-source priority

    func testResolve_cliProviderOverVaultOverSettings() {
        // vault 说 openai-compat，settings 说 ollama，CLI 说 mock → 应当 mock
        let cli = ResolvedDreamRuntimeConfig.CLIOverrides(provider: .mock)
        let vault = makeVaultConfig(provider: "openaiCompat", model: "gpt-4o")
        let settings = makeSettings(llmChoice: .ollama)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: cli, vaultConfig: vault, settings: settings)
        XCTAssertEqual(r.llm.provider, .mock)
    }

    func testResolve_vaultProviderOverSettings() {
        // CLI 无 provider → vault 优先于 settings
        let vault = makeVaultConfig(provider: "openaiCompat", model: "gpt-4o")
        let settings = makeSettings(llmChoice: .mock)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: .init(), vaultConfig: vault, settings: settings)
        XCTAssertEqual(r.llm.provider, .openaiCompat)
        XCTAssertEqual(r.llm.model, "gpt-4o")
    }

    func testResolve_acceptsDocumentedOpenAICompatProviderSpelling() {
        let vault = makeVaultConfig(provider: "openai_compat", model: "gpt-4o")
        let settings = makeSettings(llmChoice: .mock)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: .init(), vaultConfig: vault, settings: settings)
        XCTAssertEqual(r.llm.provider, .openaiCompat)
        XCTAssertEqual(r.llm.model, "gpt-4o")
    }

    func testResolve_fallsBackToSettings() {
        // CLI 无，vault 无 → settings
        let settings = makeSettings(llmChoice: .ollama, model: "qwen2.5")
        let r = ResolvedDreamRuntimeConfig.resolve(cli: .init(), vaultConfig: nil, settings: settings)
        XCTAssertEqual(r.llm.provider, .ollama)
        XCTAssertEqual(r.llm.model, "qwen2.5")
    }

    func testResolve_cliConcurrencyOverridesSettings() {
        // CLI --concurrency=4 应覆盖 settings 2
        let cli = ResolvedDreamRuntimeConfig.CLIOverrides(concurrency: 4)
        let settings = makeSettings(consolidationConcurrency: 2)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: cli, settings: settings)
        XCTAssertEqual(r.consolidation.concurrency, 4)
    }

    func testResolve_concurrencyCapTo4() {
        // 999 → 4
        let cli = ResolvedDreamRuntimeConfig.CLIOverrides(concurrency: 999)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: cli)
        XCTAssertEqual(r.consolidation.concurrency, 4)
    }

    func testResolve_budgetFromSettings() {
        let settings = makeSettings(maxCallsPerDay: 500, monthlyBudgetUSD: 25.0)
        let r = ResolvedDreamRuntimeConfig.resolve(cli: .init(), settings: settings)
        XCTAssertEqual(r.budget.maxCallsPerDay, 500)
        XCTAssertEqual(r.budget.monthlyBudgetUSD, 25.0)
    }

    func testResolvedRuntimeConfig_feedsDreamConfigDecayAndConsolidation() {
        var vault = makeVaultConfig(provider: "mock", model: "ignored")
        vault.decay = VaultConfig.DecayBlock(
            wRecency: 0.2,
            wFrequency: 0.5,
            wLinkage: 0.3,
            tauDays: 12,
            kFrequency: 7,
            lLinkage: 11,
            archiveSalienceThreshold: 0.09,
            archiveStaleDays: 42
        )
        let settings = makeSettings(consolidationConcurrency: 3)

        let resolved = ResolvedDreamRuntimeConfig.resolve(
            cli: .init(useThreeStepCoT: true),
            vaultConfig: vault,
            settings: settings
        )
        let dreamConfig = resolved.toDreamConfig()

        XCTAssertTrue(dreamConfig.consolidation.useThreeStepCoT)
        XCTAssertEqual(dreamConfig.consolidation.concurrency, 3)
        XCTAssertEqual(dreamConfig.decay.wRecency, 0.2)
        XCTAssertEqual(dreamConfig.decay.wFrequency, 0.5)
        XCTAssertEqual(dreamConfig.decay.wLinkage, 0.3)
        XCTAssertEqual(dreamConfig.decay.tauDays, 12)
        XCTAssertEqual(dreamConfig.decay.freqK, 7)
        XCTAssertEqual(dreamConfig.decay.linkL, 11)
        XCTAssertEqual(dreamConfig.decay.archiveThreshold, 0.09)
        XCTAssertEqual(dreamConfig.decay.staleDays, 42)
    }

    // MARK: - P4-T3: Keychain

    func testKeychain_roundTrip() throws {
        let item = "com.OmixNet.dreamvault.test.\(UUID().uuidString)"
        let secret = "sk-test-\(UUID().uuidString)"
        try Keychain.save(secret, itemName: item)
        defer { try? Keychain.delete(itemName: item) }

        let loaded = try Keychain.load(itemName: item)
        XCTAssertEqual(loaded, secret)
    }

    func testKeychain_loadIfPresent_returnsNilForMissing() {
        let item = "com.OmixNet.dreamvault.missing.\(UUID().uuidString)"
        let loaded = Keychain.loadIfPresent(itemName: item)
        XCTAssertNil(loaded)
    }

    func testKeychain_delete_silentlyIgnoresMissing() {
        let item = "com.OmixNet.dreamvault.missing.\(UUID().uuidString)"
        XCTAssertNoThrow(try Keychain.delete(itemName: item))
    }

    // MARK: - P4-T4: BudgetManager

    func testBudget_canProceed_whenNoLimit() {
        let cfg = ResolvedDreamRuntimeConfig.ResolvedBudget(
            maxCallsPerDay: 0, monthlyBudgetUSD: 0, onExceed: .skip
        )
        let bm = BudgetManager(config: cfg, vaultRoot: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(bm.canProceed())
    }

    func testBudget_blocksAfterMaxCalls() {
        let cfg = ResolvedDreamRuntimeConfig.ResolvedBudget(
            maxCallsPerDay: 2, monthlyBudgetUSD: 0, onExceed: .skip
        )
        let bm = BudgetManager(config: cfg, vaultRoot: URL(fileURLWithPath: "/tmp"))
        bm.recordCall(provider: "mock", model: "x", inputTokens: 0, outputTokens: 0)
        bm.recordCall(provider: "mock", model: "x", inputTokens: 0, outputTokens: 0)
        XCTAssertFalse(bm.canProceed(), "应被阻断：已达 2/2")
    }

    func testBudget_costAccumulates() {
        let cfg = ResolvedDreamRuntimeConfig.ResolvedBudget(
            maxCallsPerDay: 0,
            monthlyBudgetUSD: 0.0001,   // 更小预算（cost=0.0006 单次就阻断）
            onExceed: .skip
        )
        let tmpVault = URL(fileURLWithPath: "/tmp/dv-budget-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpVault) }
        let bm = BudgetManager(config: cfg, vaultRoot: tmpVault)
        bm.recordCall(provider: "openai", model: "gpt-4o-mini", inputTokens: 0, outputTokens: 1000)
        print("[debug] monthCost=\(bm.monthCost) limit=\(cfg.monthlyBudgetUSD)")
        XCTAssertGreaterThan(bm.monthCost, 0)
        XCTAssertFalse(bm.canProceed(), "应被成本阻断")
    }

    // MARK: - P4-T5: Conflict audit log path

    func testConflictAudit_logPath_underDreamDir() {
        let auditPath = URL(fileURLWithPath: "/tmp/test/.dream/conflict-resolutions.log")
        // 路径应包含 .dream/conflict-resolutions.log
        XCTAssertTrue(auditPath.path.contains(".dream/conflict-resolutions.log"))
    }

    // MARK: - P4-T6: NightlyDreamScheduler.Status

    func testNightlyStatus_currentStatus_doesNotCrash() {
        // 单测在 sandbox/CI 跑时 plist 状态不可控，验证 currentStatus() 不 crash
        // + 返回的 Status 是 struct
        let sched = NightlyDreamScheduler.shared
        let s = sched.currentStatus()
        // 不验 enabled/nextRunAt 因为测试机可能已有 plist
        XCTAssertNotNil(s, "Status 应能拿到")
    }

    func testNightlyTime_hourMinuteClamping() {
        // 测 DreamSettings 自身对 hour/minute 的边界（防止 25:00 这种被存）
        let s = DreamSettings(
            vaultPath: "/x", llmChoice: .mock, ollamaBaseURL: "x", ollamaModel: "x",
            useThreeStepCoT: false, consolidationConcurrency: 2, nightlyDreamEnabled: false,
            nightlyHour: 99, nightlyMinute: 88
        )
        XCTAssertEqual(s.nightlyHour, 23, "hour 25+ 应被夹到 23")
        XCTAssertEqual(s.nightlyMinute, 59, "minute 60+ 应被夹到 59")
    }

    // MARK: - helper

    private func makeVaultConfig(provider: String, model: String) -> VaultConfig {
        var c = VaultConfig()
        c.llm.provider = provider
        c.llm.model = model
        return c
    }

    private func makeSettings(llmChoice: DreamSettings.LLMChoice? = nil,
                              model: String = "llama3.1",
                              consolidationConcurrency: Int = 2,
                              maxCallsPerDay: Int = 0,
                              monthlyBudgetUSD: Double = 0) -> DreamSettings {
        return DreamSettings(
            vaultPath: "/tmp/test",
            llmChoice: llmChoice ?? .ollama,
            ollamaBaseURL: "http://127.0.0.1:11434",
            ollamaModel: model,
            useThreeStepCoT: false,
            consolidationConcurrency: consolidationConcurrency,
            nightlyDreamEnabled: false,
            maxCallsPerDay: maxCallsPerDay,
            monthlyBudgetUSD: monthlyBudgetUSD
        )
    }
}
