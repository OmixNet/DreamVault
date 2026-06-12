import Foundation

// MARK: - P9c-P0-2: Reinforcer
//
// spec 核心思想是"被访问、被确认即重置衰减曲线"，但 `reinforceCount` / `lastAccess`
// 目前没有任何 UI 行为会更新 —— 衰减只有下坡没有上坡，跑两个月所有记忆都会滑向 archive。
//
// 本类把"强化"这一动作统一收敛到单一入口 `reinforce(memoryID:source:now:)`：
//   - 防抖：同一 memoryID + 同一 source 在同一 day 内只 +1（idempotent per day per source）
//   - 持久化：走 Persister.saveLedger（沿用 P7 atomic write）
//   - 仅作用于 durable / archived 的记忆：candidate 仍处于候选区，不进入强化计数
//
// 触发点（由上层接入，不在本类内）：
//   - .wikiOpen       ：EditorPane 加载某条 memory 的 wiki 页
//   - .searchClick    ：SearchSheet 用户点中搜索结果且结果路径能映射到 memoryID
//   - .dreamReference ：Consolidator 接受新候选时，新候选引用的 sourceFiles 对应的现有 durable
//   - .manual         ：CLI / 调试手动触发

/// 强化来源类型。每种来源在同一天内只 +1。
public enum ReinforceSource: String, Codable, CaseIterable, Sendable {
    case wikiOpen
    case searchClick
    case dreamReference
    case manual

    public var label: String {
        switch self {
        case .wikiOpen:       return "wiki open"
        case .searchClick:    return "search click"
        case .dreamReference: return "dream reference"
        case .manual:         return "manual"
        }
    }
}

/// P9c-P0-2: 强化触发器。
///
/// 持有 vaultRoot + 内存中的 ledger 副本（init 时从 disk 加载），
/// 每次 reinforce 更新内存 ledger + 落盘。MainActor 持有，因为
/// （1）SwiftUI view 可能在 MainActor 订阅 reinforce 事件；
/// （2）ledger 文件 IO 走 Persister.saveLedger，与现有 dream 写入路径对齐。
@MainActor
public final class Reinforcer: ObservableObject {

    public let vaultRoot: URL

    /// 内存中的 ledger 副本。reinforce 成功后写回 Persister.saveLedger。
    private var ledger: Ledger

    /// @Published：view 想订阅（reinforce 后立刻看到 lastAccess/reinforceCount 变化）可订阅。
    /// P0-2 不强求 view 订阅，保留以便 P10+ 接 status panel / dashboard。
    @Published public private(set) var lastReinforceCount: Int = 0

    /// 最近一次 reinforce 的事件描述（debug 用：stdout / dream-report）
    @Published public private(set) var lastEvent: String = ""

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot
        self.ledger = Persister.loadLedger(vaultRoot: vaultRoot)
    }

    /// 公开测试入口：替换内存 ledger（仅测试用，生产不要调）
    public func _setLedgerForTesting(_ l: Ledger) {
        self.ledger = l
    }

    // MARK: - 主入口

    /// 强化一条记忆。同一 memoryID + source + day 内多次调用只有第一次生效。
    /// candidate 状态的记忆不会强化（按 spec：candidate 是单源观察，不算"被确认"）。
    /// 返回 true 表示本次真的 +1；false 表示被防抖掉 / memory 不存在 / 不是 durable/archived。
    @discardableResult
    public func reinforce(memoryID: String,
                          source: ReinforceSource,
                          now: Date = Date()) -> Bool {
        guard let idx = ledger.memories.firstIndex(where: { $0.id == memoryID }) else {
            return false
        }
        let mem = ledger.memories[idx]
        // candidate 不参与强化计数（spec: 单源观察仍属候选区）
        guard mem.status != .candidate else { return false }

        // 防抖：同 source 在同 day 已 reinforce 过 → 跳过
        let key = source.rawValue
        if let last = ledger.memories[idx].lastReinforceBySource[key],
           Calendar.current.isDate(last, inSameDayAs: now) {
            return false
        }

        ledger.memories[idx].reinforceCount += 1
        ledger.memories[idx].lastAccess = now
        ledger.memories[idx].lastReinforceBySource[key] = now

        // 落盘：跟 P8 / P7 一致走 atomic write
        do {
            try Persister.saveLedger(ledger, vaultRoot: vaultRoot)
        } catch {
            // 落盘失败 → 回滚内存计数（保持 ledger 与 disk 一致）
            FileHandle.standardError.write(Data(
                "[Reinforcer] saveLedger 失败：\(error.localizedDescription)；回滚内存计数\n".utf8))
            ledger.memories[idx].reinforceCount -= 1
            ledger.memories[idx].lastAccess = mem.lastAccess
            ledger.memories[idx].lastReinforceBySource[key] = mem.lastReinforceBySource[key]
            return false
        }

        lastReinforceCount = ledger.memories[idx].reinforceCount
        lastEvent = "\(now): +1 \(memoryID) via \(source.label) (now=\(ledger.memories[idx].reinforceCount))"
        return true
    }

    // MARK: - 工具方法

    /// 给定 vault 内任意 .md 文件路径，尝试映射回 memory id。
    /// wiki/{entities,concepts,syntheses}/<id>.md → id
    /// wiki/archive/<id>.md → id
    /// 其它路径返回 nil（不在强化范围）。
    public static func memoryID(forVaultFile url: URL, vaultRoot: URL) -> String? {
        let rel = Self.relativePath(of: url, vaultRoot: vaultRoot)
        let prefixes = ["wiki/entities/", "wiki/concepts/", "wiki/syntheses/", "wiki/archive/"]
        for p in prefixes where rel.hasPrefix(p) && rel.hasSuffix(".md") {
            let stem = String(rel.dropFirst(p.count).dropLast(".md".count))
            if !stem.isEmpty { return stem }
        }
        return nil
    }

    /// 同上：接受 relPath 字符串版（SearchSheet 的 SearchResult.id 就是 relPath）
    public static func memoryID(forVaultRelPath relPath: String) -> String? {
        let prefixes = ["wiki/entities/", "wiki/concepts/", "wiki/syntheses/", "wiki/archive/"]
        for p in prefixes where relPath.hasPrefix(p) && relPath.hasSuffix(".md") {
            let stem = String(relPath.dropFirst(p.count).dropLast(".md".count))
            if !stem.isEmpty { return stem }
        }
        return nil
    }

    private static func relativePath(of url: URL, vaultRoot: URL) -> String {
        let root = vaultRoot.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(root + "/") {
            return String(p.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - P9c-P0-2: bulk helper（供 DreamCycle 在 main actor 之外调用）

    /// Consolidator 接受新候选后，对所有 source files 共享的现有 durable/archived 记忆
    /// 触发 .dreamReference 强化。非 MainActor 静态方法：DreamCycle 在自己 actor 上调，
    /// 内部走 loadLedger + 内存修改 + saveLedger 一次落盘。
    ///
    /// - Parameters:
    ///   - newAcceptedSourceFiles: 新接受候选的 sourceFiles 集合（去重后）
    ///   - vaultRoot: vault 根目录
    ///   - now: 当前时间（用于 debounce）
    /// - Returns: 被强化记忆的 id 列表（debug 用 / dream-report 可选输出）
    @discardableResult
    nonisolated public static func reinforceBySourceFiles(_ newAcceptedSourceFiles: Set<String>,
                                              vaultRoot: URL,
                                              now: Date = Date()) -> [String] {
        guard !newAcceptedSourceFiles.isEmpty else { return [] }
        var ledger = loadLedger(vaultRoot: vaultRoot)
        var hit: [String] = []
        for i in ledger.memories.indices where ledger.memories[i].status != .candidate {
            let memFiles = Set(ledger.memories[i].sources.map { $0.file })
            guard !memFiles.isDisjoint(with: newAcceptedSourceFiles) else { continue }
            let key = ReinforceSource.dreamReference.rawValue
            // 同样 per-day debounce
            if let last = ledger.memories[i].lastReinforceBySource[key],
               Calendar.current.isDate(last, inSameDayAs: now) {
                continue
            }
            ledger.memories[i].reinforceCount += 1
            ledger.memories[i].lastAccess = now
            ledger.memories[i].lastReinforceBySource[key] = now
            hit.append(ledger.memories[i].id)
        }
        if !hit.isEmpty {
            try? saveLedger(ledger, vaultRoot: vaultRoot)
        }
        return hit
    }

    /// 暴露内部 loadLedger 给 nonisolated context（Persister.loadLedger 已经是 static）
    nonisolated private static func loadLedger(vaultRoot: URL) -> Ledger {
        Persister.loadLedger(vaultRoot: vaultRoot)
    }

    nonisolated private static func saveLedger(_ ledger: Ledger, vaultRoot: URL) throws {
        try Persister.saveLedger(ledger, vaultRoot: vaultRoot)
    }
}