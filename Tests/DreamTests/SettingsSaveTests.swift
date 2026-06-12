import XCTest
@testable import DreamEngine
@testable import dream
import SwiftUI
import AppKit

/// P8: Settings 全局保存 + dirty 判定测试
///
/// DreamSettings 已经是 Equatable；SettingsView 的 hasUnsavedChanges 判定逻辑
/// 必须是纯函数。SwiftUI body / onChange 这部分不直接测；测关键的「isDirty」路径。
@MainActor
final class SettingsSaveTests: XCTestCase {

    // MARK: - 简单字段 isDirty

    func testDreamSettings_equatable_detectsChange() {
        let a = DreamSettings.default
        var b = a
        XCTAssertEqual(a, b, "完全相同")
        b.consolidationConcurrency = 3
        XCTAssertNotEqual(a, b, "concurrency 改了就该算 dirty")
    }

    func testDreamSettings_equatable_detectsProviderChange() {
        let a = DreamSettings.default
        var b = a
        b.llmChoice = .mock
        XCTAssertNotEqual(a, b, "LLM 切换 = dirty")
    }

    func testDreamSettings_equatable_detectsBudgetChange() {
        let a = DreamSettings.default
        var b = a
        b.maxCallsPerDay = 100
        XCTAssertNotEqual(a, b, "预算改动 = dirty")
    }

    func testDreamSettings_savePersistsAndReload() {
        // 起一个临时的 UserDefaults pool
        let suite = UserDefaults(suiteName: "dv-p8-settings-\(UUID().uuidString)")!
        defer { UserDefaults().removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "") }

        // 写 → 读回 → 等价
        var s = DreamSettings.default
        s.ollamaModel = "qwen2.5:7b"
        s.useThreeStepCoT = true
        s.consolidationConcurrency = 4
        s.maxCallsPerDay = 50
        s.redactBeforeConsolidate = false
        s.allowCloudSendRawSummary = true
        s.diagnosticsIncludePath = false
        s.nightlyHour = 4
        s.nightlyMinute = 30

        // DreamSettings.save() 写 standard，不是 suite。验证：写 + load 还能 round-trip
        s.save()
        let loaded = DreamSettings.load()
        XCTAssertEqual(loaded.ollamaModel, "qwen2.5:7b", "ollamaModel round-trip")
        XCTAssertEqual(loaded.useThreeStepCoT, true, "useThreeStepCoT round-trip")
        XCTAssertEqual(loaded.consolidationConcurrency, 4, "concurrency round-trip")
        XCTAssertEqual(loaded.maxCallsPerDay, 50, "budget round-trip")
        XCTAssertEqual(loaded.allowCloudSendRawSummary, true, "privacy round-trip")
        XCTAssertEqual(loaded.nightlyHour, 4, "nightly hour round-trip")
        XCTAssertEqual(loaded.nightlyMinute, 30, "nightly minute round-trip")
    }

    // MARK: - P8 关键: 所有字段都被 save()

    func testDreamSettings_saveCoversAllFields() {
        // 改动每一个字段，save，再 load，确认没有字段被 save() 漏掉
        let baseline = DreamSettings.load()
        var s = baseline
        s.vaultPath = "/tmp/p8-vault-\(UUID().uuidString)"
        s.llmChoice = .openaiCompat
        s.ollamaBaseURL = "https://api.example.com/v1"
        s.ollamaModel = "gpt-test"
        s.useThreeStepCoT = !baseline.useThreeStepCoT
        s.consolidationConcurrency = 4
        s.nightlyDreamEnabled = !baseline.nightlyDreamEnabled
        s.maxCallsPerDay = 999
        s.monthlyBudgetUSD = 12.34
        s.maxRawFilesPerRun = 200
        s.redactBeforeConsolidate = !baseline.redactBeforeConsolidate
        s.allowCloudSendRawSummary = !baseline.allowCloudSendRawSummary
        s.diagnosticsIncludePath = !baseline.diagnosticsIncludePath
        s.diagnosticsIncludeLogs = !baseline.diagnosticsIncludeLogs
        s.nightlyHour = 5
        s.nightlyMinute = 45

        s.save()
        let reloaded = DreamSettings.load()

        XCTAssertEqual(reloaded.vaultPath, s.vaultPath)
        XCTAssertEqual(reloaded.llmChoice, s.llmChoice)
        XCTAssertEqual(reloaded.ollamaBaseURL, s.ollamaBaseURL)
        XCTAssertEqual(reloaded.ollamaModel, s.ollamaModel)
        XCTAssertEqual(reloaded.useThreeStepCoT, s.useThreeStepCoT)
        XCTAssertEqual(reloaded.consolidationConcurrency, s.consolidationConcurrency)
        XCTAssertEqual(reloaded.nightlyDreamEnabled, s.nightlyDreamEnabled)
        XCTAssertEqual(reloaded.maxCallsPerDay, s.maxCallsPerDay)
        XCTAssertEqual(reloaded.monthlyBudgetUSD, s.monthlyBudgetUSD)
        XCTAssertEqual(reloaded.maxRawFilesPerRun, s.maxRawFilesPerRun)
        XCTAssertEqual(reloaded.redactBeforeConsolidate, s.redactBeforeConsolidate)
        XCTAssertEqual(reloaded.allowCloudSendRawSummary, s.allowCloudSendRawSummary)
        XCTAssertEqual(reloaded.diagnosticsIncludePath, s.diagnosticsIncludePath)
        XCTAssertEqual(reloaded.diagnosticsIncludeLogs, s.diagnosticsIncludeLogs)
        XCTAssertEqual(reloaded.nightlyHour, s.nightlyHour)
        XCTAssertEqual(reloaded.nightlyMinute, s.nightlyMinute)

        // 清理：恢复 baseline，避免污染后续 test
        baseline.save()
    }
}
