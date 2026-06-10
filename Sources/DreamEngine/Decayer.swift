import Foundation

/// 衰减参数，全部可调（对应架构文档第 4 节）
public struct DecayConfig {
    public var wRecency: Double = 0.5
    public var wFrequency: Double = 0.3
    public var wLinkage: Double = 0.2
    public var tauDays: Double = 30      // recency 基准时间常数 baseTau（实际 τ = baseTau × decayClass 系数）
    public var freqK: Double = 5         // frequency 饱和常数
    public var linkL: Double = 8         // linkage 归一上限
    public var archiveThreshold: Double = 0.15   // 低于此且久未访问 → 降级
    public var staleDays: Double = 90            // "久未访问"的门槛

    public init() {}
}

public enum DecayAction: Equatable {
    case keep
    case archive          // 降级到 archive/，不删
    case needsReview      // 有矛盾，交人工
}

public struct DecayResult: Equatable {
    public let memoryID: String
    public let salience: Double
    public let action: DecayAction
}

public struct Decayer {
    public let config: DecayConfig
    public init(config: DecayConfig = DecayConfig()) { self.config = config }

    /// 实际生效的 τ：baseTau × 类型系数（slow=3.0 / normal=1.0 / fast=0.3）
    /// normal 的系数为 1.0，故旧行为完全不变（只扩展）。
    public func effectiveTau(for m: Memory) -> Double {
        config.tauDays * m.decayClass.tauMultiplier
    }

    /// 计算单条记忆的显著度 ∈ [0,1]
    public func salience(of m: Memory, now: Date = Date()) -> Double {
        let dtDays = max(0, now.timeIntervalSince(m.lastAccess) / 86_400)
        let recency = exp(-dtDays / effectiveTau(for: m))
        let frequency = 1 - exp(-Double(m.reinforceCount) / config.freqK)
        let linkage = min(1, Double(m.inboundLinks) / config.linkL)
        let s = config.wRecency * recency
              + config.wFrequency * frequency
              + config.wLinkage * linkage
        return min(1, max(0, s))
    }

    /// 决定一条记忆的命运。保守优先：宁可 keep，绝不物理删除。
    public func evaluate(_ m: Memory, now: Date = Date()) -> DecayResult {
        let s = salience(of: m, now: now)

        // 矛盾永远优先交人工，不自动处理
        if !m.contradicts.isEmpty {
            return DecayResult(memoryID: m.id, salience: s, action: .needsReview)
        }
        // archived 的不再重复降级
        if m.status == .archived {
            return DecayResult(memoryID: m.id, salience: s, action: .keep)
        }
        let dtDays = now.timeIntervalSince(m.lastAccess) / 86_400
        if s < config.archiveThreshold && dtDays > config.staleDays {
            return DecayResult(memoryID: m.id, salience: s, action: .archive)
        }
        return DecayResult(memoryID: m.id, salience: s, action: .keep)
    }

    public func evaluateAll(_ ledger: Ledger, now: Date = Date()) -> [DecayResult] {
        ledger.memories.map { evaluate($0, now: now) }
    }
}
