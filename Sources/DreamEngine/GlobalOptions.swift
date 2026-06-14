import Foundation

// MARK: - GlobalOptions（dream CLI 共享的全局参数）
//
// 放在 DreamEngine 库中是因为 Tests target 需要 import 来测参数解析。
// dream CLI 自己的 main.swift 也 import 用。
public struct GlobalOptions {
    public var vault: String?
    public var llm: String?
    public var verbose: Bool = false

    public struct RuntimeContext: @unchecked Sendable {
        public let resolved: ResolvedDreamRuntimeConfig
        public let provider: any LLMProvider
        public let budgetManager: BudgetManager
        public let dreamConfig: DreamConfig
    }

    public enum RuntimeConfigError: Error, LocalizedError, CustomStringConvertible {
        case cloudProviderRequiresConsent

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .cloudProviderRequiresConsent:
                return "OpenAI-compatible provider requires explicit privacy consent before sending raw summaries to a cloud API."
            }
        }
    }

    /// 从 args 列表里抽走全局 flag（inout 修改原数组）
    public static func parse(from args: inout [String]) -> GlobalOptions {
        var o = GlobalOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--vault":
                if i + 1 < args.count {
                    o.vault = args[i + 1]
                    args.removeSubrange(i...i + 1)
                } else { i += 1 }
            case "--llm":
                if i + 1 < args.count {
                    o.llm = args[i + 1]
                    args.removeSubrange(i...i + 1)
                } else { i += 1 }
            case "--verbose", "-v":
                o.verbose = true
                args.remove(at: i)
            default:
                i += 1
            }
        }
        return o
    }

    /// 解析 --vault，未指定则用 $DREAMVAULT_VAULT 或 $HOME/.dreamvault
    public func vaultURL() -> URL {
        let path = vault
            ?? ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"]
            ?? "\(NSHomeDirectory())/.dreamvault"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    /// 决定 LLM provider。P8 修复：走 ResolvedConfig 5 层合并，跟 GUI 同源
    /// (CLI flag > .dream/config.json > UserDefaults > env vars > hardcoded)
    public func llmProvider() -> LLMProvider {
        let resolved = (try? resolvedRuntimeConfig(writeDefaultVaultConfig: false))
            ?? ResolvedDreamRuntimeConfig.resolve(
                cli: ResolvedDreamRuntimeConfig.CLIOverrides(provider: parseProvider(llm)),
                settings: DreamSettings.load()
            )
        return makeProvider(from: resolved)
    }

    public func resolvedRuntimeConfig(writeDefaultVaultConfig: Bool = true) throws -> ResolvedDreamRuntimeConfig {
        let vault = vaultURL()
        let env = ProcessInfo.processInfo.environment
        let configURL = VaultConfig.configURL(vaultRoot: vault)
        let vaultConfig: VaultConfig? = FileManager.default.fileExists(atPath: configURL.path)
            ? try DreamConfigLoader.load(vaultRoot: vault, writeDefaultIfMissing: false)
            : nil
        return ResolvedDreamRuntimeConfig.resolve(
            cli: ResolvedDreamRuntimeConfig.CLIOverrides(
                provider: parseProvider(llm),
                model: env["OLLAMA_MODEL"],
                baseURL: env["OLLAMA_BASE_URL"]
            ),
            vaultConfig: vaultConfig,
            settings: DreamSettings.load(),
            env: env
        )
    }

    /// 决定 LLM provider + 包一层 BudgetedLLMProvider。
    /// 任何时候 CLI / launchd 调 cmdRun 都应该走这个（不是 llmProvider()），
    /// 否则预算只是"检查器"不记录。
    public func budgetedLLMProvider() async -> (provider: any LLMProvider, budgetManager: BudgetManager) {
        let context = try? await runtimeContext()
        if let context {
            return (context.provider, context.budgetManager)
        }
        let vault = vaultURL()
        let resolved = ResolvedDreamRuntimeConfig.resolve(
            cli: ResolvedDreamRuntimeConfig.CLIOverrides(provider: parseProvider(llm)),
            settings: DreamSettings.load()
        )
        let base = makeProvider(from: resolved)
        let providerName: String
        switch resolved.llm.provider {
        case .mock: providerName = "mock"
        case .ollama: providerName = "ollama"
        case .openaiCompat: providerName = "openai-compat"
        }
        // BudgetManager 是 @MainActor 持有，clamp 到 Sendable closure 里要 await
        let budget = await MainActor.run {
            BudgetManager(config: resolved.budget, vaultRoot: vault)
        }
        let canProceedFn: @Sendable (_ estOutTok: Int, _ modelHint: String) async -> Bool = { estOutTok, modelHint in
            await MainActor.run { budget.canProceed(estimatedOutputTokens: estOutTok, modelHint: modelHint) }
        }
        let recordCallFn: @Sendable (String, String, Int, Int) async -> Void = { p, m, i, o in
            await MainActor.run {
                budget.recordCall(provider: p, model: m, inputTokens: i, outputTokens: o)
            }
        }
        let wrapped = BudgetedLLMProvider(
            wrapping: base,
            providerName: providerName,
            canProceedFn: canProceedFn,
            recordCallFn: recordCallFn
        )
        return (wrapped, budget)
    }

    public func runtimeContext(writeDefaultVaultConfig: Bool = true) async throws -> RuntimeContext {
        let vault = vaultURL()
        let resolved = try resolvedRuntimeConfig(writeDefaultVaultConfig: writeDefaultVaultConfig)
        if resolved.llm.provider == .openaiCompat,
           !resolved.privacy.allowCloudSendRawSummary {
            throw RuntimeConfigError.cloudProviderRequiresConsent
        }
        let base = makeProvider(from: resolved)
        let providerName: String
        switch resolved.llm.provider {
        case .mock: providerName = "mock"
        case .ollama: providerName = "ollama"
        case .openaiCompat: providerName = "openai-compat"
        }
        let budget = await MainActor.run {
            BudgetManager(config: resolved.budget, vaultRoot: vault)
        }
        let canProceedFn: @Sendable (_ estOutTok: Int, _ modelHint: String) async -> Bool = { estOutTok, modelHint in
            await MainActor.run { budget.canProceed(estimatedOutputTokens: estOutTok, modelHint: modelHint) }
        }
        let recordCallFn: @Sendable (String, String, Int, Int) async -> Void = { p, m, i, o in
            await MainActor.run {
                budget.recordCall(provider: p, model: m, inputTokens: i, outputTokens: o)
            }
        }
        let wrapped = BudgetedLLMProvider(
            wrapping: base,
            providerName: providerName,
            canProceedFn: canProceedFn,
            recordCallFn: recordCallFn
        )
        return RuntimeContext(
            resolved: resolved,
            provider: wrapped,
            budgetManager: budget,
            dreamConfig: resolved.toDreamConfig()
        )
    }

    /// 把 CLI 字符串 (--llm ollama / mock / openai) 翻译成 ResolvedLLM.Provider
    private func parseProvider(_ s: String?) -> ResolvedDreamRuntimeConfig.ResolvedLLM.Provider? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        return ResolvedDreamRuntimeConfig.parseProvider(s)
    }

    /// 从 ResolvedConfig 转成 LLMProvider
    private func makeProvider(from r: ResolvedDreamRuntimeConfig) -> LLMProvider {
        switch r.llm.provider {
        case .mock:
            return MockLLMProvider()
        case .ollama, .openaiCompat:
            // 两个 provider 共用 OllamaProvider 实现（OpenAI 兼容协议）
            let apiKey: String?
            if r.llm.provider == .openaiCompat, let item = r.llm.keychainItem {
                apiKey = Keychain.loadIfPresent(itemName: item)
            } else {
                apiKey = nil
            }
            return OllamaProvider(baseURL: r.llm.baseURL, model: r.llm.model, apiKey: apiKey)
        }
    }

    /// 显式构造（测试用）
    public init(vault: String? = nil, llm: String? = nil, verbose: Bool = false) {
        self.vault = vault
        self.llm = llm
        self.verbose = verbose
    }
}
