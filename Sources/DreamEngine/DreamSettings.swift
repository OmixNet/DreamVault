import Foundation

/// DreamVault 用户偏好设置。**全部走 UserDefaults** 持久化（macOS 原生）。
///
/// 之前所有配置（DREAMVAULT_LLM / OLLAMA_BASE_URL / OLLAMA_MODEL / 3-Step /
/// 并发数）都靠环境变量。Mac App 用户不碰环境变量 → P3-T7 把所有可调项
/// 搬进 Settings 面板。
///
/// 优先级（解析时高→低）：
/// 1. UserDefaults 显式设置（用户改过 Settings）
/// 2. 环境变量（CLI 启动时设的，给 cron / launchd 留逃生口）
/// 3. 硬编码默认值
public struct DreamSettings: Equatable, Sendable {

    public enum LLMChoice: String, CaseIterable, Sendable {
        case mock
        case ollama
        case openaiCompat

        public var displayName: String {
            switch self {
            case .mock: return "Mock (no network)"
            case .ollama: return "Ollama (local LLM)"
            case .openaiCompat: return "OpenAI-Compatible (cloud)"
            }
        }
    }

    public var vaultPath: String
    public var llmChoice: LLMChoice
    public var ollamaBaseURL: String
    public var ollamaModel: String
    public var useThreeStepCoT: Bool
    public var consolidationConcurrency: Int  // 1...4
    public var nightlyDreamEnabled: Bool       // P3-T9: SMAppService toggle

    // P4-T4 / T7: budget + privacy
    public var maxCallsPerDay: Int              // 0 = 不限（本地默认）
    public var monthlyBudgetUSD: Double        // 0 = 不限
    public var maxRawFilesPerRun: Int          // per-run gather cap
    public var redactBeforeConsolidate: Bool   // PII 脱敏（之前在 ConsolidationConfig）
    public var allowCloudSendRawSummary: Bool   // 默认 false（关）
    public var diagnosticsIncludePath: Bool
    public var diagnosticsIncludeLogs: Bool
    public var nightlyHour: Int                 // P4-T6: 几点跑
    public var nightlyMinute: Int               // P4-T6: 几分跑

    public static let `default` = DreamSettings(
        vaultPath: "\(NSHomeDirectory())/.dreamvault",
        llmChoice: .ollama,
        ollamaBaseURL: "http://127.0.0.1:11434",
        ollamaModel: "llama3.1",
        useThreeStepCoT: false,
        consolidationConcurrency: 2,
        nightlyDreamEnabled: false,
        maxCallsPerDay: 0,            // 本地默认无限
        monthlyBudgetUSD: 0,          // 本地默认无限
        maxRawFilesPerRun: 20,
        redactBeforeConsolidate: true,
        allowCloudSendRawSummary: false,
        diagnosticsIncludePath: true,
        diagnosticsIncludeLogs: true,
        nightlyHour: 3,
        nightlyMinute: 0
    )

    // MARK: - UserDefaults key
    private enum Key {
        static let vaultPath = "DreamVault.vaultPath"
        static let llmChoice = "DreamVault.llmChoice"
        static let ollamaBaseURL = "DreamVault.ollamaBaseURL"
        static let ollamaModel = "DreamVault.ollamaModel"
        static let useThreeStepCoT = "DreamVault.useThreeStepCoT"
        static let consolidationConcurrency = "DreamVault.consolidationConcurrency"
        static let nightlyDreamEnabled = "DreamVault.nightlyDreamEnabled"
        static let maxCallsPerDay = "DreamVault.maxCallsPerDay"
        static let monthlyBudgetUSD = "DreamVault.monthlyBudgetUSD"
        static let maxRawFilesPerRun = "DreamVault.maxRawFilesPerRun"
        static let redactBeforeConsolidate = "DreamVault.redactBeforeConsolidate"
        static let allowCloudSendRawSummary = "DreamVault.allowCloudSendRawSummary"
        static let diagnosticsIncludePath = "DreamVault.diagnosticsIncludePath"
        static let diagnosticsIncludeLogs = "DreamVault.diagnosticsIncludeLogs"
        static let nightlyHour = "DreamVault.nightlyHour"
        static let nightlyMinute = "DreamVault.nightlyMinute"
    }

    public init(vaultPath: String,
                llmChoice: LLMChoice,
                ollamaBaseURL: String,
                ollamaModel: String,
                useThreeStepCoT: Bool,
                consolidationConcurrency: Int,
                nightlyDreamEnabled: Bool,
                maxCallsPerDay: Int = 0,
                monthlyBudgetUSD: Double = 0,
                maxRawFilesPerRun: Int = 20,
                redactBeforeConsolidate: Bool = true,
                allowCloudSendRawSummary: Bool = false,
                diagnosticsIncludePath: Bool = true,
                diagnosticsIncludeLogs: Bool = true,
                nightlyHour: Int = 3,
                nightlyMinute: Int = 0) {
        self.vaultPath = vaultPath
        self.llmChoice = llmChoice
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModel = ollamaModel
        self.useThreeStepCoT = useThreeStepCoT
        self.consolidationConcurrency = max(1, min(4, consolidationConcurrency))
        self.nightlyDreamEnabled = nightlyDreamEnabled
        self.maxCallsPerDay = maxCallsPerDay
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.maxRawFilesPerRun = maxRawFilesPerRun
        self.redactBeforeConsolidate = redactBeforeConsolidate
        self.allowCloudSendRawSummary = allowCloudSendRawSummary
        self.diagnosticsIncludePath = diagnosticsIncludePath
        self.diagnosticsIncludeLogs = diagnosticsIncludeLogs
        self.nightlyHour = max(0, min(23, nightlyHour))
        self.nightlyMinute = max(0, min(59, nightlyMinute))
    }

    /// 从 UserDefaults 读（带 fallback 到 .default）。env var 不参与（Settings 是 GUI 独立）。
    public static func load() -> DreamSettings {
        let d = UserDefaults.standard
        let llmRaw = d.string(forKey: Key.llmChoice) ?? LLMChoice.ollama.rawValue
        let llm = LLMChoice(rawValue: llmRaw) ?? .ollama
        return DreamSettings(
            vaultPath: d.string(forKey: Key.vaultPath) ?? Self.default.vaultPath,
            llmChoice: llm,
            ollamaBaseURL: d.string(forKey: Key.ollamaBaseURL) ?? Self.default.ollamaBaseURL,
            ollamaModel: d.string(forKey: Key.ollamaModel) ?? Self.default.ollamaModel,
            useThreeStepCoT: d.object(forKey: Key.useThreeStepCoT) as? Bool ?? Self.default.useThreeStepCoT,
            consolidationConcurrency: d.object(forKey: Key.consolidationConcurrency) as? Int ?? Self.default.consolidationConcurrency,
            nightlyDreamEnabled: d.bool(forKey: Key.nightlyDreamEnabled),
            maxCallsPerDay: d.object(forKey: Key.maxCallsPerDay) as? Int ?? Self.default.maxCallsPerDay,
            monthlyBudgetUSD: d.object(forKey: Key.monthlyBudgetUSD) as? Double ?? Self.default.monthlyBudgetUSD,
            maxRawFilesPerRun: d.object(forKey: Key.maxRawFilesPerRun) as? Int ?? Self.default.maxRawFilesPerRun,
            redactBeforeConsolidate: d.object(forKey: Key.redactBeforeConsolidate) as? Bool ?? Self.default.redactBeforeConsolidate,
            allowCloudSendRawSummary: d.object(forKey: Key.allowCloudSendRawSummary) as? Bool ?? Self.default.allowCloudSendRawSummary,
            diagnosticsIncludePath: d.object(forKey: Key.diagnosticsIncludePath) as? Bool ?? Self.default.diagnosticsIncludePath,
            diagnosticsIncludeLogs: d.object(forKey: Key.diagnosticsIncludeLogs) as? Bool ?? Self.default.diagnosticsIncludeLogs,
            nightlyHour: d.object(forKey: Key.nightlyHour) as? Int ?? Self.default.nightlyHour,
            nightlyMinute: d.object(forKey: Key.nightlyMinute) as? Int ?? Self.default.nightlyMinute
        )
    }

    /// 写到 UserDefaults
    public func save() {
        let d = UserDefaults.standard
        d.set(vaultPath, forKey: Key.vaultPath)
        d.set(llmChoice.rawValue, forKey: Key.llmChoice)
        d.set(ollamaBaseURL, forKey: Key.ollamaBaseURL)
        d.set(ollamaModel, forKey: Key.ollamaModel)
        d.set(useThreeStepCoT, forKey: Key.useThreeStepCoT)
        d.set(consolidationConcurrency, forKey: Key.consolidationConcurrency)
        d.set(nightlyDreamEnabled, forKey: Key.nightlyDreamEnabled)
        d.set(maxCallsPerDay, forKey: Key.maxCallsPerDay)
        d.set(monthlyBudgetUSD, forKey: Key.monthlyBudgetUSD)
        d.set(maxRawFilesPerRun, forKey: Key.maxRawFilesPerRun)
        d.set(redactBeforeConsolidate, forKey: Key.redactBeforeConsolidate)
        d.set(allowCloudSendRawSummary, forKey: Key.allowCloudSendRawSummary)
        d.set(diagnosticsIncludePath, forKey: Key.diagnosticsIncludePath)
        d.set(diagnosticsIncludeLogs, forKey: Key.diagnosticsIncludeLogs)
        d.set(nightlyHour, forKey: Key.nightlyHour)
        d.set(nightlyMinute, forKey: Key.nightlyMinute)
    }

    // MARK: - 应用到引擎

    /// 把当前 settings 翻译成 ConsolidationConfig（给 DreamCycle 用）
    public func consolidationConfig() -> ConsolidationConfig {
        ConsolidationConfig(
            useThreeStepCoT: useThreeStepCoT,
            concurrency: consolidationConcurrency
        )
    }

    /// 把当前 settings 翻译成 LLMProvider（给 DreamCycle 用）
    public func makeLLMProvider() -> LLMProvider {
        switch llmChoice {
        case .mock:
            return MockLLMProvider()
        case .ollama:
            let base = URL(string: ollamaBaseURL)
                ?? URL(string: "http://127.0.0.1:11434")!
            return OllamaProvider(baseURL: base, model: ollamaModel)
        case .openaiCompat:
            let base = URL(string: ollamaBaseURL)
                ?? URL(string: "http://127.0.0.1:11434")!
            // P4-T3: API key 走 Keychain
            let key = Keychain.loadIfPresent(itemName: "com.OmixNet.dreamvault.openai-key")
            return OllamaProvider(baseURL: base, model: ollamaModel, apiKey: key)
        }
    }
}
