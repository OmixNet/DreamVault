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

        public var displayName: String {
            switch self {
            case .mock: return "Mock (no network)"
            case .ollama: return "Ollama (local LLM)"
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

    public static let `default` = DreamSettings(
        vaultPath: "\(NSHomeDirectory())/.dreamvault",
        llmChoice: .ollama,
        ollamaBaseURL: "http://127.0.0.1:11434",
        ollamaModel: "llama3.1",
        useThreeStepCoT: false,
        consolidationConcurrency: 2,
        nightlyDreamEnabled: false
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
    }

    public init(vaultPath: String,
                llmChoice: LLMChoice,
                ollamaBaseURL: String,
                ollamaModel: String,
                useThreeStepCoT: Bool,
                consolidationConcurrency: Int,
                nightlyDreamEnabled: Bool) {
        self.vaultPath = vaultPath
        self.llmChoice = llmChoice
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModel = ollamaModel
        self.useThreeStepCoT = useThreeStepCoT
        self.consolidationConcurrency = max(1, min(4, consolidationConcurrency))
        self.nightlyDreamEnabled = nightlyDreamEnabled
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
            nightlyDreamEnabled: d.bool(forKey: Key.nightlyDreamEnabled)
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
        }
    }
}
