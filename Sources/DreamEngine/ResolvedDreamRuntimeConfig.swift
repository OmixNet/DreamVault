import Foundation

// MARK: - ResolvedDreamRuntimeConfig
//
// P4-T1: 统一所有"用户在某处配的"配置入口——CLI flags、vault 内 config.json、
// app-level UserDefaults、env vars、hardcoded defaults——按优先级合并成一个
// 不可变 struct，DreamCycle 跑时只看这一份。
//
// 之前的链路：
//   CLI: GlobalOptions().llmProvider()   ← 只看 env vars
//   GUI: AppModel.runDream              ← GlobalOptions().llmProvider()
//   VaultConfig (.dream/config.json)   ← Decayer 调，但 llm/apiKey 没接
//   DreamSettings (UserDefaults)        ← P3 加了但 runDream 没用
//
// 新链路（自顶向下，命中即停）：
//   1. CLI flag (--llm ollama --vault X)         （最高，run-once override）
//   2. .dream/config.json (VaultConfig)           （vault 级，每 vault 不同）
//   3. UserDefaults (DreamSettings)               （app 级，GUI 改的）
//   4. env vars (DREAMVAULT_LLM / OLLAMA_BASE_URL)（系统级，cron/launchd 留逃生口）
//   5. hardcoded defaults                         （最低，零配置能跑）
//
// **优先级穿透**：高优覆盖低优的**整个 provider 配置块**（不是逐字段 merge）。
// 例：CLI 给 --llm ollama --ollama-model qwen → 整段 provider 走 CLI，不管
// vault config 里写了什么 provider。
public struct ResolvedDreamRuntimeConfig: Equatable, Sendable {

    // MARK: - LLM

    public let llm: ResolvedLLM
    public struct ResolvedLLM: Equatable, Sendable {
        public let provider: Provider
        public let model: String
        public let baseURL: URL
        /// Keychain item name (or "none" for providers that don't need one)
        public let keychainItem: String?
        /// max tokens for output（云模型成本控制）
        public let maxOutputTokens: Int
        /// Per-request timeout (seconds)
        public let timeoutSeconds: Int

        public enum Provider: String, Equatable, Sendable {
            case mock
            case ollama
            case openaiCompat  // OpenAI 兼容 (SiliconFlow / DeepSeek / OpenAI 等)
            /// v0.6 PR 36: Anthropic Messages API. Uses `x-api-key` header
            /// and `anthropic-version: 2023-06-01`. NOT OpenAI-compat.
            case anthropic
            /// v0.6 PR 36: Google Gemini generateContent API. Uses
            /// `x-goog-api-key` header. NOT OpenAI-compat, NOT Anthropic.
            case gemini
        }
    }

    // MARK: - Consolidation

    public let consolidation: ResolvedConsolidation
    public struct ResolvedConsolidation: Equatable, Sendable {
        public let useThreeStepCoT: Bool
        public let concurrency: Int
        public let maxRetries: Int
        public let timeoutSeconds: Int
    }

    // MARK: - Gather budget (P4-T4)

    public let gather: ResolvedGather
    public struct ResolvedGather: Equatable, Sendable {
        /// max raw files per dream run
        public let maxFilesPerRun: Int
        /// soft warning per file size (MB)
        public let softFileSizeMB: Int
        /// hard stop per file size (MB)
        public let hardFileSizeMB: Int
    }

    // MARK: - Daily budget (P4-T4)

    public let budget: ResolvedBudget
    public struct ResolvedBudget: Equatable, Sendable {
        /// max LLM calls per day（0 = 无限制）
        public let maxCallsPerDay: Int
        /// monthly budget in USD (0 = 无限制)
        public let monthlyBudgetUSD: Double
        /// behavior when exceeded: .skip / .prompt
        public let onExceed: ExceedBehavior
        public enum ExceedBehavior: String, Equatable, Sendable {
            case skip  // skip remaining candidates for this run
            case prompt  // GUI 弹 alert；CLI 视为 skip
        }
    }

    // MARK: - Privacy (P4-T7)

    public let privacy: ResolvedPrivacy
    public struct ResolvedPrivacy: Equatable, Sendable {
        public let redactBeforeConsolidate: Bool
        /// 是否允许把 raw 摘要发到云（用户必须显式确认；Ollama 本地不受影响）
        public let allowCloudSendRawSummary: Bool
    }

    // MARK: - Decay (passes through to Decayer)

    public let decay: ResolvedDecay
    public struct ResolvedDecay: Equatable, Sendable {
        public let wRecency: Double
        public let wFrequency: Double
        public let wLinkage: Double
        public let tauDays: Double
        public let kFrequency: Double
        public let lLinkage: Double
        public let archiveSalienceThreshold: Double
        public let archiveStaleDays: Double
    }

    // MARK: - Resolver

    /// CLI-level overrides（最高优先）；nil = 用下面层的
    public struct CLIOverrides: Equatable, Sendable {
        public var provider: ResolvedLLM.Provider?
        public var model: String?
        public var baseURL: String?
        public var useThreeStepCoT: Bool?
        public var concurrency: Int?
        public init(provider: ResolvedLLM.Provider? = nil,
                    model: String? = nil,
                    baseURL: String? = nil,
                    useThreeStepCoT: Bool? = nil,
                    concurrency: Int? = nil) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
            self.useThreeStepCoT = useThreeStepCoT
            self.concurrency = concurrency
        }
    }

    /// 把 5 层源合并成一份最终 config
    /// - cliOverrides: CLI flag 解析出来的（最高）
    /// - vaultConfig: .dream/config.json 读出来的（per-vault，可选）
    /// - settings: UserDefaults 读出来的（app-level，可选）
    /// - env: ProcessInfo.processInfo.environment
    /// 5. hardcoded defaults（已藏在 DreamSettings.default + VaultConfig 默认）
    public static func resolve(cli: CLIOverrides = .init(),
                               vaultConfig: VaultConfig? = nil,
                               settings: DreamSettings = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedDreamRuntimeConfig {

        // 1. provider：CLI > vault > settings > env > default
        let provider: ResolvedLLM.Provider = {
            if let p = cli.provider { return p }
            if let p = vaultConfig?.llm.provider,
               let parsed = Self.parseProvider(p) { return parsed }
            // settings.llmChoice 是 .mock / .ollama（仅 2 选 1）；云端走
            // vault config 的 keychainItemName 触发 openaiCompat 路径
            switch settings.llmChoice {
            case .mock: return .mock
            case .ollama: return .ollama
            case .openaiCompat: return .openaiCompat
            }
        }()

        // 2. model / baseURL：CLI > vault > settings (按 provider 类型取)
        let model: String = {
            if let m = cli.model { return m }
            if let m = vaultConfig?.llm.model, !m.isEmpty { return m }
            return settings.ollamaModel
        }()
        let baseURLString: String = {
            if let u = cli.baseURL { return u }
            if let u = vaultConfig?.llm.baseURL, !u.isEmpty { return u }
            return settings.ollamaBaseURL
        }()
        let baseURL = URL(string: baseURLString)
            ?? URL(string: "http://127.0.0.1:11434")!

        // 3. keychainItem: vault config 的 apiKey 不再直存（Keychain），
        //    而是 keychainItem 引用。CLI 不支持（一次性的 key 走环境）。
        let keychainItem: String? = vaultConfig?.llm.keychainItemName
            ?? Self.defaultKeychainItem(for: provider)

        // 4. maxOutputTokens / timeout
        let maxOutputTokens = 800   // P4-T1 固定保守默认；后续 Settings 调
        let timeoutSeconds = 120

        let llm = ResolvedLLM(
            provider: provider,
            model: model,
            baseURL: baseURL,
            keychainItem: keychainItem,
            maxOutputTokens: maxOutputTokens,
            timeoutSeconds: timeoutSeconds
        )

        // consolidation
        let useThreeStepCoT = cli.useThreeStepCoT
            ?? settings.useThreeStepCoT
        let concurrency = cli.concurrency
            ?? settings.consolidationConcurrency
        let consolidation = ResolvedConsolidation(
            useThreeStepCoT: useThreeStepCoT,
            concurrency: max(1, min(4, concurrency)),
            maxRetries: 3,
            timeoutSeconds: 120
        )

        // gather
        let gather = ResolvedGather(
            maxFilesPerRun: settings.maxRawFilesPerRun,
            softFileSizeMB: 1,
            hardFileSizeMB: 5
        )

        // budget（从 UserDefaults settings 读，CLI/env 不覆盖）
        let budget = ResolvedBudget(
            maxCallsPerDay: settings.maxCallsPerDay,
            monthlyBudgetUSD: settings.monthlyBudgetUSD,
            onExceed: .skip
        )

        // privacy
        let privacy = ResolvedPrivacy(
            redactBeforeConsolidate: settings.redactBeforeConsolidate,
            allowCloudSendRawSummary: settings.allowCloudSendRawSummary
        )

        // decay
        let decay = ResolvedDecay(
            wRecency: vaultConfig?.decay.wRecency ?? 0.5,
            wFrequency: vaultConfig?.decay.wFrequency ?? 0.3,
            wLinkage: vaultConfig?.decay.wLinkage ?? 0.2,
            tauDays: vaultConfig?.decay.tauDays ?? 30,
            kFrequency: vaultConfig?.decay.kFrequency ?? 5,
            lLinkage: vaultConfig?.decay.lLinkage ?? 8,
            archiveSalienceThreshold: vaultConfig?.decay.archiveSalienceThreshold ?? 0.15,
            archiveStaleDays: vaultConfig?.decay.archiveStaleDays ?? 90
        )

        return ResolvedDreamRuntimeConfig(
            llm: llm,
            consolidation: consolidation,
            gather: gather,
            budget: budget,
            privacy: privacy,
            decay: decay
        )
    }

    public func toConsolidationConfig() -> ConsolidationConfig {
        ConsolidationConfig(
            redactBeforeConsolidate: privacy.redactBeforeConsolidate,
            useThreeStepCoT: consolidation.useThreeStepCoT,
            concurrency: consolidation.concurrency
        )
    }

    public func toDecayConfig() -> DecayConfig {
        DecayConfig(
            wRecency: decay.wRecency,
            wFrequency: decay.wFrequency,
            wLinkage: decay.wLinkage,
            tauDays: decay.tauDays,
            freqK: decay.kFrequency,
            linkL: decay.lLinkage,
            archiveThreshold: decay.archiveSalienceThreshold,
            staleDays: decay.archiveStaleDays
        )
    }

    public func toDreamConfig(embeddingProvider: EmbeddingProvider? = nil,
                              embeddingTopK: Int = 5,
                              embeddingSimilarityThreshold: Double = 0.5) -> DreamConfig {
        DreamConfig(
            consolidation: toConsolidationConfig(),
            decay: toDecayConfig(),
            embeddingProvider: embeddingProvider,
            embeddingTopK: embeddingTopK,
            embeddingSimilarityThreshold: embeddingSimilarityThreshold
        )
    }

    /// provider 默认 Keychain item 命名
    private static func defaultKeychainItem(for provider: ResolvedLLM.Provider) -> String? {
        switch provider {
        case .mock, .ollama: return nil
        case .openaiCompat: return "com.OmixNet.dreamvault.openai-key"
        case .anthropic: return "com.OmixNet.dreamvault.anthropic-key"
        case .gemini: return "com.OmixNet.dreamvault.gemini-key"
        }
    }

    static func parseProvider(_ raw: String) -> ResolvedLLM.Provider? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mock":
            return .mock
        case "ollama":
            return .ollama
        case "openai", "openai_compat", "openai-compat", "openaicompat":
            return .openaiCompat
        case "anthropic", "claude":
            // v0.6 PR 36: accept both "anthropic" (canonical) and "claude"
            // (colloquial) so users running `dream --llm claude` get the
            // right provider.
            return .anthropic
        case "gemini", "google", "google-gemini":
            // v0.6 PR 36: accept "gemini" / "google" / "google-gemini".
            return .gemini
        default:
            return ResolvedLLM.Provider(rawValue: raw)
        }
    }
}
