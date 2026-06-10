import Foundation

// MARK: - 来源引用（防幻觉的基石：每条教训都必须能追溯到 raw 行）

public struct SourceRef: Codable, Equatable, Hashable {
    public let file: String      // raw/ 下的相对路径
    public let line: Int         // 起始行
    public let excerpt: String   // 原文片段，供回读校验与人工审查

    public init(file: String, line: Int, excerpt: String) {
        self.file = file; self.line = line; self.excerpt = excerpt
    }
}

// MARK: - 一条教训 / 记忆

public enum MemoryStatus: String, Codable {
    case candidate   // 单源观察，仅进 wiki 候选区
    case durable     // 多源支撑，进 MEMORY.md
    case archived    // 被衰减降级，移入 archive，可找回
}

// MARK: - 衰减类别（REFERENCE_SPEC 附录：τ = baseTau × 类型系数）

public enum DecayClass: String, Codable, CaseIterable {
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

public struct Memory: Codable, Identifiable, Equatable {
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

    public init(id: String = UUID().uuidString,
                text: String,
                sources: [SourceRef],
                status: MemoryStatus = .candidate,
                createdAt: Date = Date(),
                lastAccess: Date = Date(),
                reinforceCount: Int = 0,
                inboundLinks: Int = 0,
                contradicts: [String] = [],
                decayClass: DecayClass = .normal) {
        self.id = id; self.text = text; self.sources = sources
        self.status = status; self.createdAt = createdAt
        self.lastAccess = lastAccess; self.reinforceCount = reinforceCount
        self.inboundLinks = inboundLinks; self.contradicts = contradicts
        self.decayClass = decayClass
    }

    /// 自定义解码：旧 ledger.json 没有 decayClass 字段时默认 normal，保持向后兼容
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
    }

    /// 独立来源数（按文件去重）——决定能否从 candidate 升为 durable
    public var distinctSourceCount: Int {
        Set(sources.map { $0.file }).count
    }
}

// MARK: - 衰减账本（.dream/ledger.json）

public struct Ledger: Codable {
    public var memories: [Memory]
    public init(memories: [Memory] = []) { self.memories = memories }
}
