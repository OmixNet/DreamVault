import Foundation

// MARK: - VaultConfig（.dream/config.json 的磁盘形态）
//
// 对应架构文档第 1 节："dream 引擎的元数据 → .dream/config.json → LLM 选择、
// 衰减参数、调度"。本结构是用户写在 vault 里的可调参数；与运行时的
// `DreamConfig` / `ConsolidationConfig` 是不同的概念——后者是程序级调参，
// 前者是 vault 级（同一个二进制可挂多个 vault，每个 vault 自己的设置）。
//
// 字段默认值保持当前引擎行为（向后兼容）：
// - llm.provider = "mock"          → 默认本地 mock（零依赖）
// - decay.*      = 与 DecayConfig 默认一致（w_r=0.5/w_f=0.3/w_l=0.2/τ=30/k=5/L=8/archive<0.15/stale=90）
// - gather.requireFrontmatterProcessedFalse = true  → 与 Gatherer 当前行为一致
public struct VaultConfig: Codable, Sendable, Equatable {

    public var llm: LLMBlock
    public var decay: DecayBlock
    public var gather: GatherBlock

    public init(llm: LLMBlock = LLMBlock(),
                decay: DecayBlock = DecayBlock(),
                gather: GatherBlock = GatherBlock()) {
        self.llm = llm; self.decay = decay; self.gather = gather
    }

    // MARK: - llm 块

    public struct LLMBlock: Codable, Sendable, Equatable {
        /// "mock" | "ollama" | "openai_compat"
        public var provider: String
        /// 模型名（mock 时可忽略；ollama/openai_compat 必填）
        public var model: String
        /// 完整 baseURL（含 scheme + host + port），如
        /// "http://127.0.0.1:11434" 或 "https://api.siliconflow.cn/v1"。
        /// Ollama 工厂会自动追加 "/v1/chat/completions"；openai_compat 直接用原值。
        public var baseURL: String?
        /// P4-T3: Keychain item 引用（推荐）。OAuth-style secret 不应明文存 vault
        /// （vault 是 git repo，所有人 commit 都能看到）。
        /// 例如 "com.OmixNet.dreamvault.openai-key" —— 实际 key 走
        /// `security find-generic-password -s <item>` 读。
        public var keychainItemName: String?
        /// 已弃用：明文 API key。仅供向后兼容（v0.3.x → v0.4 仍能读）。
        /// **写** 时强制为 nil；**读** 时如果非 nil 会被 console warning + 忽略。
        public var apiKey: String?

        public init(provider: String = "mock",
                    model: String = "llama3.1",
                    baseURL: String? = nil,
                    keychainItemName: String? = nil,
                    apiKey: String? = nil) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
            self.keychainItemName = keychainItemName
            self.apiKey = apiKey
        }
    }

    // MARK: - decay 块

    public struct DecayBlock: Codable, Sendable, Equatable {
        public var wRecency: Double
        public var wFrequency: Double
        public var wLinkage: Double
        public var tauDays: Double
        public var kFrequency: Double
        public var lLinkage: Double
        public var archiveSalienceThreshold: Double
        public var archiveStaleDays: Double

        public init(wRecency: Double = 0.5,
                    wFrequency: Double = 0.3,
                    wLinkage: Double = 0.2,
                    tauDays: Double = 30,
                    kFrequency: Double = 5,
                    lLinkage: Double = 8,
                    archiveSalienceThreshold: Double = 0.15,
                    archiveStaleDays: Double = 90) {
            self.wRecency = wRecency
            self.wFrequency = wFrequency
            self.wLinkage = wLinkage
            self.tauDays = tauDays
            self.kFrequency = kFrequency
            self.lLinkage = lLinkage
            self.archiveSalienceThreshold = archiveSalienceThreshold
            self.archiveStaleDays = archiveStaleDays
        }

        /// 转成 Decayer 用的内部 DecayConfig
        public func toDecayConfig() -> DecayConfig {
            var c = DecayConfig()
            c.wRecency = wRecency
            c.wFrequency = wFrequency
            c.wLinkage = wLinkage
            c.tauDays = tauDays
            c.freqK = kFrequency
            c.linkL = lLinkage
            c.archiveThreshold = archiveSalienceThreshold
            c.staleDays = archiveStaleDays
            return c
        }
    }

    // MARK: - gather 块

    public struct GatherBlock: Codable, Sendable, Equatable {
        /// 严格要求 raw/ 文件 frontmatter 显式标 processed:false 才收。
        /// 默认 true：保持当前 Gatherer 的行为（显式 processed:false 必收，
        /// 无声明也按"未声明"对待；true:false 才决定收不收）。
        public var requireFrontmatterProcessedFalse: Bool

        public init(requireFrontmatterProcessedFalse: Bool = true) {
            self.requireFrontmatterProcessedFalse = requireFrontmatterProcessedFalse
        }
    }

    // MARK: - 文件路径

    /// `.dream/config.json` 的标准位置
    public static func configURL(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".dream/config.json")
    }
}

// MARK: - DreamConfigLoader（加载/写入 .dream/config.json）
//
// 设计要点：
// - 文件不存在 → 写默认 config.json 进去，**继续**（不抛错），让"刚 init 完的
//   vault 立刻能跑 dream"成为零配置体验。
// - 文件存在但解析失败 → 抛错（让用户知道他们的 JSON 坏了；不静默回退，
//   否则调参失效也察觉不到）。
// - JSON 字段缺失（部分 schema 缺失）→ 用 default；只对"完全坏掉"的 JSON 抛错。
public enum DreamConfigLoader {

    /// 从 vault 根目录加载配置。文件缺失则**写入默认**并返回默认；解析失败抛错。
    /// - Parameter writeDefaultIfMissing: 文件不存在时是否回写默认。默认 true。
    ///   单元测试中可传 false 避免污染临时目录。
    public static func load(vaultRoot: URL, writeDefaultIfMissing: Bool = true) throws -> VaultConfig {
        let url = VaultConfig.configURL(vaultRoot: vaultRoot)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let cfg = VaultConfig()
            if writeDefaultIfMissing {
                try save(cfg, vaultRoot: vaultRoot)
            }
            return cfg
        }
        let data = try Data(contentsOf: url)
        // 容错：空文件当 default
        if data.isEmpty { return VaultConfig() }
        do {
            return try JSONDecoder().decode(VaultConfig.self, from: data)
        } catch {
            throw DreamConfigError.malformedJSON(
                "解析 .dream/config.json 失败：\(error.localizedDescription)")
        }
    }

    /// 把配置写到 .dream/config.json。pretty-printed + sorted keys，便于 git diff。
    public static func save(_ config: VaultConfig, vaultRoot: URL) throws {
        let url = VaultConfig.configURL(vaultRoot: vaultRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public enum DreamConfigError: Error, CustomStringConvertible {
        case malformedJSON(String)
        public var description: String {
            switch self {
            case .malformedJSON(let s): return s
            }
        }
    }
}

// MARK: - LLMFactory.fromConfig（基于 VaultConfig.LLMBlock 构造 provider）
//
// 替换 `fromEnvironment()` 作为推荐入口；保留旧入口做 deprecation alias
// （不影响 CLI 现有 --llm 标志行为）。
public extension LLMFactory {
    /// 从 VaultConfig.LLMBlock 构造 provider。
    /// - provider == "mock" / 缺省 → MockLLMProvider
    /// - provider == "ollama"        → OllamaProvider（baseURL 缺省用 localhost:11434）
    /// - provider == "openai_compat" → OpenAICompatibleProvider（直接用 baseURL 整段）
    /// - 未知 provider → stderr 警告 + 回退 mock，不让一次配置错误炸掉整次 dream
    static func fromConfig(_ block: VaultConfig.LLMBlock) -> LLMProvider {
        switch block.provider.lowercased() {
        case "mock":
            return MockLLMProvider()
        case "ollama":
            let rawBase = block.baseURL ?? "http://127.0.0.1:11434"
            // OllamaProvider 便捷构造会自动追加 /v1/chat/completions，所以传 base 不带 /v1
            let baseURL = URL(string: rawBase) ?? URL(string: "http://127.0.0.1:11434")!
            return OllamaProvider(baseURL: baseURL, model: block.model)
        case "openai_compat":
            // 用户必须给完整 endpoint（含 /v1/chat/completions）
            guard let base = block.baseURL,
                  let url = URL(string: base) else {
                FileHandle.standardError.write(Data(
                    "[LLMFactory] openai_compat 但 baseURL 缺失或非法，回退 MockLLMProvider\n".utf8))
                return MockLLMProvider()
            }
            return OllamaProvider(
                baseURL: url, model: block.model, apiKey: block.apiKey)
        default:
            FileHandle.standardError.write(Data(
                "[LLMFactory] provider='\(block.provider)' 未知，回退 MockLLMProvider\n".utf8))
            return MockLLMProvider()
        }
    }
}