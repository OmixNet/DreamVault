import Foundation

// MARK: - 来源引用（防幻觉的基石：每条教训都必须能追溯到 raw 行）

public struct SourceRef: Codable, Equatable, Hashable, Sendable {
    public let file: String      // raw/ 下的相对路径
    public let line: Int         // 起始行
    public let excerpt: String   // 原文片段，供回读校验与人工审查

    public init(file: String, line: Int, excerpt: String) {
        self.file = file; self.line = line; self.excerpt = excerpt
    }
}

// MARK: - 一条教训 / 记忆

// MARK: - 记忆状态（ADR-0003: 6 态生命周期）
//
// 状态机：
//   candidate → durable → reinforced ↔ durable
//                            ↓
//                          decayed → archived
//   任何状态 + 矛盾 → conflict → durable/archived (人工裁决)
//
// 向后兼容：老 ledger.json 只含 candidate/durable/archived 三个值，
// 自定义 init(from:) 在 §老 ledger 解码段给后三个新状态打默认值。
public enum MemoryStatus: String, Codable, Sendable {
    case candidate   // 单源观察，仅进 wiki 候选区
    case durable     // 多源支撑，进 MEMORY.md
    case reinforced  // 近期被访问/链接/用户确认 → 衰减更慢（ADR-0003 §Lifecycle states）
    case decayed     // 低于 durable 基准但高于 archive 阈值（中间可观测态）
    case archived    // 被衰减降级，移入 archive，可找回
    case conflict    // 与另一条 memory 矛盾，等待人工裁决（不静默删）
}

// MARK: - 记忆分类（架构文档第 1 节 wiki/{entities,concepts,syntheses}/）
//
// 决定 Persister 写到 wiki/ 哪个子目录。默认 .concept，向后兼容老 ledger。
// 加新分类时同步更新 Memory.kindSafe / Persister.wikiRelPath 的 switch 即可。
public enum MemoryKind: String, Codable, Sendable, CaseIterable {
    case entity     // 实体页：人/项目/工具
    case concept    // 概念页：抽象模式/规则
    case synthesis  // 综合页：跨实体/概念的整合

    /// 老 ledger 没 kind 字段时的默认（保持向后兼容）
    public static let defaultKind: MemoryKind = .concept
}

// MARK: - 衰减类别（REFERENCE_SPEC 附录：τ = baseTau × 类型系数）

public enum DecayClass: String, Codable, Sendable, CaseIterable {
    case slow     // 架构决策类，衰减慢（τ × 3.0，默认 ≈ 90 天）
    case normal   // 一般教训（τ × 1.0）
    case fast     // 临时 bug 类，衰减快（τ × 0.3，默认 ≈ 9 天）

    /// recency 时间常数的类型系数
    public var tauMultiplier: Double {
        switch self {
        case .slow:   return 3.0
        case .normal: return 1.0
        case .fast:   return 0.3
        }
    }
}

public struct Memory: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String                 // 提炼出的规则/教训
    public var sources: [SourceRef]          // 至少 1 条；durable 需 ≥2 独立源
    public var status: MemoryStatus
    public var createdAt: Date
    public var lastAccess: Date             // 最后被引用/强化时间
    public var reinforceCount: Int          // 被强化次数
    public var inboundLinks: Int            // 被多少 wiki 页引用
    public var contradicts: [String]        // 冲突教训的 id，交人工裁决
    public var decayClass: DecayClass       // 衰减类别，决定 τ 的类型系数
    /// 记忆分类（架构文档第 1 节 wiki/{entities,concepts,syntheses}/）
    public var kind: MemoryKind
    /// 相关/矛盾的双向链接存储（id 列表）。避免扫整盘 graph 算 related 时再去 lookup。
    /// 与 `contradicts` 不同：relatedTo 是"general"相关（含矛盾），contradicts 专指冲突。
    public var relatedTo: [String]
    /// P9c-P0-2: 每个 source (raw/...) 最近一次 reinforce 的日期（per-day debounce）。
    /// key = ReinforceSource.rawValue, value = 上次 reinforce 的 Date（实际只用到日期部分）。
    /// 旧 ledger 没有此字段 → 默认空（首次 reinforce 会写回）。
    public var lastReinforceBySource: [String: Date]

    // MARK: - ADR-0003 新增字段（6 态生命周期 + 5 项 salience）

    /// 最近一次"被强化"的时间。nil = 从未被强化过。
    /// 驱动 durable ↔ reinforced 切换：超过 reinforcedThreshold 时间未强化 → 回到 durable。
    /// 老 ledger 没有此字段 → 默认 nil（首次 reinforce 时写回）。
    public var lastReinforcedAt: Date?

    /// 5 项加权 salience 的缓存值。nil = 还没算过（首次 Decayer.run 后会写）。
    /// 不序列化到 JSON（每次 dream run 都重算）；写回会让 ledger.json 变得脆弱。
    public var salienceScore: Double? = nil

    public init(id: String = UUID().uuidString,
                text: String,
                sources: [SourceRef],
                status: MemoryStatus = .candidate,
                createdAt: Date = Date(),
                lastAccess: Date = Date(),
                reinforceCount: Int = 0,
                inboundLinks: Int = 0,
                contradicts: [String] = [],
                decayClass: DecayClass = .normal,
                kind: MemoryKind = MemoryKind.defaultKind,
                relatedTo: [String] = [],
                lastReinforceBySource: [String: Date] = [:],
                lastReinforcedAt: Date? = nil,
                salienceScore: Double? = nil) {
        self.id = id; self.text = text; self.sources = sources
        self.status = status; self.createdAt = createdAt
        self.lastAccess = lastAccess; self.reinforceCount = reinforceCount
        self.inboundLinks = inboundLinks; self.contradicts = contradicts
        self.decayClass = decayClass
        self.kind = kind
        self.relatedTo = relatedTo
        self.lastReinforceBySource = lastReinforceBySource
        self.lastReinforcedAt = lastReinforcedAt
        self.salienceScore = salienceScore
    }

    /// 自定义解码：旧 ledger.json 没有 kind/relatedTo/decayClass 字段时
    /// 给默认值，保持向后兼容
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        sources = try c.decode([SourceRef].self, forKey: .sources)
        status = try c.decode(MemoryStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastAccess = try c.decode(Date.self, forKey: .lastAccess)
        reinforceCount = try c.decode(Int.self, forKey: .reinforceCount)
        inboundLinks = try c.decode(Int.self, forKey: .inboundLinks)
        contradicts = try c.decode([String].self, forKey: .contradicts)
        decayClass = try c.decodeIfPresent(DecayClass.self, forKey: .decayClass) ?? .normal
        // kind / relatedTo：旧 ledger 没有时按架构默认值回退
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? MemoryKind.defaultKind
        relatedTo = try c.decodeIfPresent([String].self, forKey: .relatedTo) ?? []
        // P9c-P0-2: lastReinforceBySource 旧 ledger 没有时给空 dict（首次 reinforce 会写回）
        lastReinforceBySource = try c.decodeIfPresent([String: Date].self,
                                                     forKey: .lastReinforceBySource) ?? [:]
        // ADR-0003: lastReinforcedAt 旧 ledger 没有时给 nil（首次 reinforce 会写回）
        lastReinforcedAt = try c.decodeIfPresent(Date.self, forKey: .lastReinforcedAt)
        // ADR-0003: salienceScore 永远不序列化到 JSON（每次 dream run 重算），
        // 但为安全保留 decodeIfPresent，nil 也 OK
        salienceScore = try c.decodeIfPresent(Double.self, forKey: .salienceScore)
    }

    /// 独立来源数（按文件去重）——决定能否从 candidate 升为 durable
    public var distinctSourceCount: Int {
        Set(sources.map { $0.file }).count
    }
}

// MARK: - 衰减账本（.dream/ledger.json）

public struct Ledger: Codable, Sendable {
    public var memories: [Memory]
    public init(memories: [Memory] = []) { self.memories = memories }
}
