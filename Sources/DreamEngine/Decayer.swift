import Foundation

/// 衰减参数，全部可调（对应架构文档第 4 节）
///
/// P3-7 评审 §2.1 修复:
/// 1. `staleDays` 也按 `tauMultiplier` 缩放 (fast 27 天 / normal 90 天 / slow 270 天).
///    老实现: staleDays 固定 90 天 for 所有 decayClass, fast 类 9 天 τ 在第 10 天
///    salience ≈ 0 仍要等满 90 天, stale 门槛被架空.
/// 2. `frequency` 加新近度衰减 (新参数 `frequencyTauDays = 60`). 4 次强化 = 永生
///    修了: `w_f·(1-e^(-n/5))·e^(-dt/freqTau) ≥ 0.15` 在 n=4 时恒成立 (老问题),
///    乘 e^(-dt/60) 后 n=4 在 dt=60 天频率地板降到 0.27, 90 天后几乎全衰减.
public struct DecayConfig: Sendable {
    public var wRecency: Double = 0.5
    public var wFrequency: Double = 0.3
    public var wLinkage: Double = 0.2
    public var tauDays: Double = 30      // recency 基准时间常数 baseTau（实际 τ = baseTau × decayClass 系数）
    public var freqK: Double = 5         // frequency 饱和常数
    public var linkL: Double = 8         // linkage 归一上限
    public var archiveThreshold: Double = 0.15   // 低于此且久未访问 → 降级
    /// "久未访问"的基准门槛. 实际门槛 = staleDays × decayClass.tauMultiplier
    /// (评审 §2.1: fast 27 天 / normal 90 天 / slow 270 天, 跟 τ 比例一致)
    public var staleDays: Double = 90
    /// P3-7 评审 §2.1 修复 #2: frequency 新近度衰减时间常数.
    /// 4 次强化 (reinforceCount=4) 的 frequency ≈ 0.55, w_f=0.3 → 0.165 (≥ 0.15 archive 阈值).
    /// 乘 e^(-dt/freqTau) 后 dt=60 天频率地板 0.27 → 0.55·0.37 = 0.20, 90 天后 ≈ 0.10.
    /// 不让"4 次强化 = 永生": 强化过的知识长期不访问也该被衰减, 跟 recency 平衡.
    public var frequencyTauDays: Double = 60

    public init() {}

    /// Memberwise init (P3-7 评审 §2.1 修复 #2 加 frequencyTauDays 后允许测试单参数 override)
    public init(wRecency: Double = 0.5,
                wFrequency: Double = 0.3,
                wLinkage: Double = 0.2,
                tauDays: Double = 30,
                freqK: Double = 5,
                linkL: Double = 8,
                archiveThreshold: Double = 0.15,
                staleDays: Double = 90,
                frequencyTauDays: Double = 60) {
        self.wRecency = wRecency
        self.wFrequency = wFrequency
        self.wLinkage = wLinkage
        self.tauDays = tauDays
        self.freqK = freqK
        self.linkL = linkL
        self.archiveThreshold = archiveThreshold
        self.staleDays = staleDays
        self.frequencyTauDays = frequencyTauDays
    }
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

    /// P3-7 §2.1 修复 #1: 实际生效的 stale 门槛 = staleDays × decayClass.tauMultiplier.
    /// 跟 effectiveTau 同步缩放, fast 27 天 / normal 90 天 / slow 270 天.
    /// 老行为 (正常 90 天) 在 normal decayClass 下完全不变 (系数 1.0).
    public func effectiveStaleDays(for m: Memory) -> Double {
        config.staleDays * m.decayClass.tauMultiplier
    }

    /// 计算单条记忆的显著度 ∈ [0,1]
    /// P3-7 §2.1 修复 #2: frequency 乘 e^(-dt/freqTau) 新近度衰减.
    /// - dt=0: 衰减系数 1.0 (老行为)
    /// - dt=60: 衰减系数 ≈ 0.37 (frequency 衰减 63%)
    /// - dt=∞: 衰减系数 0 (frequency 完全失效, 走纯 recency)
    public func salience(of m: Memory, now: Date = Date()) -> Double {
        let dtDays = max(0, now.timeIntervalSince(m.lastAccess) / 86_400)
        let recency = exp(-dtDays / effectiveTau(for: m))
        // P3-7: frequency 乘新近度衰减. 让"高频但长期不访问"也按时间衰减.
        let frequencyBase = 1 - exp(-Double(m.reinforceCount) / config.freqK)
        let frequencyDecay = exp(-dtDays / config.frequencyTauDays)
        let frequency = frequencyBase * frequencyDecay
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
        // P3-7 §2.1 修复 #1: 实际 stale 门槛按 tauMultiplier 缩放.
        // 老实现: 固定 90 天 for 所有 decayClass. fast 类 9 天 τ 在第 10 天
        // salience 已 ≈ 0, 但仍要等满 90 天 → stale 门槛被架空.
        let dtDays = now.timeIntervalSince(m.lastAccess) / 86_400
        if s < config.archiveThreshold && dtDays > effectiveStaleDays(for: m) {
            return DecayResult(memoryID: m.id, salience: s, action: .archive)
        }
        return DecayResult(memoryID: m.id, salience: s, action: .keep)
    }

    public func evaluateAll(_ ledger: Ledger, now: Date = Date()) -> [DecayResult] {
        ledger.memories.map { evaluate($0, now: now) }
    }
}
