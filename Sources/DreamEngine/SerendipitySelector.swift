// P2-4: 偶然唤回 — 从 vault 选 1 条 "30+ 天没看" 的 durable memory 重新唤起
import Foundation

/// P2-4: 偶然唤回结果
public struct SerendipityPick: Equatable, Sendable {
    public let memory: Memory
    public let daysSinceAccess: Int
    public let lastAccess: Date

    public init(memory: Memory, daysSinceAccess: Int, lastAccess: Date) {
        self.memory = memory
        self.daysSinceAccess = daysSinceAccess
        self.lastAccess = lastAccess
    }
}

/// P2-4: 选 1 条 "好久没看" 的记忆
///
/// 规则:
/// 1. 只看 durable (status == .durable)
/// 2. lastAccess 距今 ≥ minDays (默认 30 天)
/// 3. 候选 ≥ 1 才返回, 否则 nil
/// 4. 多个候选: 优先 30-90 天 (太老的唤回也用处不大), 随机选 1 条 (用 stable hash 让同日多次启动稳定)
public enum SerendipitySelector {
    public static let defaultMinDays: Int = 30
    public static let maxDays: Int = 90  // 90 天以上的太老, 排除

    /// 选 1 条 (确定性, 同样输入同样输出)
    /// - Parameters:
    ///   - memories: vault 所有 memories
    ///   - now: 当前时间 (test 注入用, 默认 Date())
    ///   - minDays: 阈值天数 (默认 30)
    /// - Returns: 1 条 pick, 无合格候选返 nil
    public static func pick(from memories: [Memory],
                            now: Date = Date(),
                            minDays: Int = defaultMinDays) -> SerendipityPick? {
        let calendar = Calendar(identifier: .gregorian)
        let nowDay = calendar.startOfDay(for: now)
        var candidates: [(Memory, Int, Date)] = []
        for m in memories where m.status == .durable {
            let accessDay = calendar.startOfDay(for: m.lastAccess)
            guard let days = calendar.dateComponents([.day], from: accessDay, to: nowDay).day,
                  days >= minDays,
                  days <= maxDays else { continue }
            candidates.append((m, days, m.lastAccess))
        }
        if candidates.isEmpty { return nil }
        // 优先 30-60 天 (中等老, 唤回价值最高) — 取离 45 天最近的 1 个
        let sweetSpot = candidates.sorted { lhs, rhs in
            let lhsDist = abs(lhs.1 - 45)  // 离 45 天最近
            let rhsDist = abs(rhs.1 - 45)
            if lhsDist != rhsDist { return lhsDist < rhsDist }
            return lhs.0.id < rhs.0.id
        }
        // 多个候选时确定性 hash 选 1 (保证同日多次启动稳定)
        let top = Array(sweetSpot.prefix(max(3, sweetSpot.count / 4)))
        let seedKey = top.map { "\($0.0.id)" }.joined(separator: "|")
        let dayKey = Int(nowDay.timeIntervalSince1970 / 86400)
        let seed = stableHash("\(seedKey)|\(dayKey)")
        let chosen = top[Int(seed % UInt64(top.count))]
        return SerendipityPick(memory: chosen.0, daysSinceAccess: chosen.1, lastAccess: chosen.2)
    }

    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 5381
        for byte in s.utf8 {
            h = (h &* 33) &+ UInt64(byte)
        }
        return h
    }
}
