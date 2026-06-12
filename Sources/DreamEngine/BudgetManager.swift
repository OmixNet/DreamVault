import Foundation

/// P4-T4: LLM 调用预算管理。
///
/// 追踪每日 LLM 调用次数 + 估算成本。
/// - 本地 Ollama: cost = 0（无 API 费），但仍记调用次数防止失控
/// - 云 API: cost = 估算（output_tokens * 厂商 $/1k tokens 系数；粗略即可）
///
/// 持久化：每日一个 .dream/budget-YYYY-MM-DD.json（不进 git，写到本地 vault
/// 状态目录）。多 vault 各自独立计数。
@MainActor
public final class BudgetManager: ObservableObject {
    public struct CallRecord: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let provider: String
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let costUSD: Double
    }

    @Published public private(set) var todayCount: Int = 0
    @Published public private(set) var todayCost: Double = 0
    @Published public private(set) var monthCost: Double = 0
    @Published public private(set) var lastCall: CallRecord? = nil

    public let config: ResolvedDreamRuntimeConfig.ResolvedBudget
    private let vaultRoot: URL
    private let priceTable: [String: PricePer1k]  // model -> $ / 1k output tokens
    private var todayRecords: [CallRecord] = []

    public struct PricePer1k: Sendable {
        public let inputPer1k: Double
        public let outputPer1k: Double
    }

    /// 价格表（粗略）。Ollama 本地 = 0。
    public static let defaultPrices: [String: PricePer1k] = [
        // Ollama 本地 = 免费
        // OpenAI
        "gpt-4o-mini": .init(inputPer1k: 0.00015, outputPer1k: 0.0006),
        "gpt-4o": .init(inputPer1k: 0.0025, outputPer1k: 0.01),
        "gpt-4.1-mini": .init(inputPer1k: 0.0004, outputPer1k: 0.0016),
        // Anthropic
        "claude-3-5-haiku-20241022": .init(inputPer1k: 0.001, outputPer1k: 0.005),
        "claude-3-5-sonnet-20241022": .init(inputPer1k: 0.003, outputPer1k: 0.015),
        // DeepSeek
        "deepseek-chat": .init(inputPer1k: 0.0001, outputPer1k: 0.0002),
        // SiliconFlow / OpenAI-compatible 默认
        "Qwen/Qwen2.5-7B-Instruct": .init(inputPer1k: 0.00035, outputPer1k: 0.00035),
    ]

    public init(config: ResolvedDreamRuntimeConfig.ResolvedBudget,
                vaultRoot: URL,
                priceTable: [String: PricePer1k] = defaultPrices) {
        self.config = config
        self.vaultRoot = vaultRoot
        self.priceTable = priceTable
        loadToday()
        loadMonth()
    }

    /// 决定该不该继续调用。返回 true = 通过；false = 超额阻断。
    public func canProceed() -> Bool {
        // maxCallsPerDay > 0 才检查每日调用上限（0 = 无限制）
        if config.maxCallsPerDay > 0, todayCount >= config.maxCallsPerDay {
            FileHandle.standardError.write(Data(
                "[BudgetManager] 阻断：今日已 \(todayCount)/\(config.maxCallsPerDay) 次调用\n".utf8))
            return false
        }
        // monthlyBudgetUSD > 0 才检查月度成本（0 = 无限制）
        if config.monthlyBudgetUSD > 0, monthCost >= config.monthlyBudgetUSD {
            FileHandle.standardError.write(Data(
                "[BudgetManager] 阻断：本月成本 $\(String(format: "%.4f", monthCost))/$\(config.monthlyBudgetUSD)\n".utf8))
            return false
        }
        return true
    }

    /// 记录一次 LLM 调用
    public func recordCall(provider: String, model: String,
                           inputTokens: Int, outputTokens: Int) {
        let price = priceTable[model]
        let cost = price.map {
            Double(inputTokens) / 1000.0 * $0.inputPer1k +
            Double(outputTokens) / 1000.0 * $0.outputPer1k
        } ?? 0.0
        let rec = CallRecord(
            timestamp: Date(),
            provider: provider, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens,
            costUSD: cost
        )
        todayRecords.append(rec)
        todayCount += 1
        todayCost += cost
        monthCost += cost
        lastCall = rec
        saveToday()
        saveMonth()
    }

    // MARK: - 持久化

    private var todayFile: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return vaultRoot.appendingPathComponent(".dream/budget-\(f.string(from: Date())).json")
    }

    private var monthFile: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return vaultRoot.appendingPathComponent(".dream/budget-\(f.string(from: Date())).json")
    }

    private func loadToday() {
        guard let data = try? Data(contentsOf: todayFile),
              let recs = try? JSONDecoder().decode([CallRecord].self, from: data) else {
            return
        }
        todayRecords = recs
        todayCount = recs.count
        todayCost = recs.reduce(0) { $0 + $1.costUSD }
    }

    private func saveToday() {
        try? FileManager.default.createDirectory(
            at: vaultRoot.appendingPathComponent(".dream"),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(todayRecords) {
            try? data.write(to: todayFile)
        }
    }

    private func loadMonth() {
        guard let data = try? Data(contentsOf: monthFile),
              let recs = try? JSONDecoder().decode([CallRecord].self, from: data) else {
            return
        }
        monthCost = recs.reduce(0) { $0 + $1.costUSD }
    }

    private func saveMonth() {
        try? FileManager.default.createDirectory(
            at: vaultRoot.appendingPathComponent(".dream"),
            withIntermediateDirectories: true)
        // 简化：month 文件 = load 出来 + 今天 new records
        var all: [CallRecord] = []
        if let data = try? Data(contentsOf: monthFile),
           let existing = try? JSONDecoder().decode([CallRecord].self, from: data) {
            all = existing
        }
        // 去重：如果今天 record 的 timestamp 已在 all，跳过
        for r in todayRecords where !all.contains(where: { $0.timestamp == r.timestamp }) {
            all.append(r)
        }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: monthFile, options: .atomic)
        }
    }
}
