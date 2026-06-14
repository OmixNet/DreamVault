import Foundation

/// P0 致命修复 (缺陷报告 §1.1): RelatedCache 24h TTL 缓存 topRelated 结果.
///
/// 背景: Persister.swift:99 每晚对所有 active memory 调 graph.topRelated, O(N²) 总开销.
/// N=10000 时 = 100M ops, ~30s 卡顿. N=100000 不可用.
///
/// 修法:
/// - NSLock 保护 cache dict (线程安全, 但**同步**调用, 跟 Persister 同步 API 兼容).
/// - 24h TTL, maxHops=2 跳数剪枝 (O(N) 平均, 几秒).
/// - Persister 调 `cache.topRelated(to:in:limit:)` 替代直接调 graph.
///
/// 设计:
/// - **class + NSLock** (而非 actor) 是因为 Persister.persist 是 sync throws.
///   actor 必须 await, 改 Persister 签名影响 8 个 test 文件; class 同步可达 0 退化.
/// - TTL 默认 86400s (24h), 跟 dream nightly 频率对齐.
/// - rebuild 是同步重算 (几秒), 但 NSLock 不阻塞其他查询 (无 await).
/// - `clear()` 公开, 让 Persister 在 graph 重大变更后强制重算.
public final class RelatedCache: @unchecked Sendable {
    public struct Config: Sendable {
        public var ttl: TimeInterval = 86400          // 24h
        public var maxHops: Int? = 2                 // P0 致命修复: 跳数剪枝
        public init(ttl: TimeInterval = 86400, maxHops: Int? = 2) {
            self.ttl = ttl
            self.maxHops = maxHops
        }
    }

    private let lock = NSLock()
    private var cache: [String: [(id: String, score: Double)]] = [:]
    private var lastBuild: Date = .distantPast
    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 拿 node 关联节点. 缓存命中返缓存, 失效 (TTL 过) 自动 rebuild.
    /// - 第一次调用某 node 触发全图 rebuild (cohort, 一次性成本).
    /// - 后续 24h 内直接查表.
    public func topRelated(to id: String, in graph: KnowledgeGraph, limit: Int = 5) -> [(id: String, score: Double)] {
        lock.lock()
        let stale = Date().timeIntervalSince(lastBuild) >= config.ttl || cache.isEmpty
        lock.unlock()
        if stale {
            rebuild(from: graph)
        }
        lock.lock()
        let all = cache[id] ?? []
        lock.unlock()
        if all.count > limit {
            return Array(all.prefix(limit))
        }
        return all
    }

    /// 全图重算 (跳数剪枝). 一次性成本几秒, 24h 内复用.
    public func rebuild(from graph: KnowledgeGraph) {
        var new: [String: [(id: String, score: Double)]] = [:]
        new.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            new[node] = graph.topRelated(to: node, limit: 5, maxHops: config.maxHops)
        }
        lock.lock()
        cache = new
        lastBuild = Date()
        lock.unlock()
    }

    /// 清缓存 (graph 重大变更后调用, e.g. Persister 持久化新节点).
    public func clear() {
        lock.lock()
        cache.removeAll()
        lastBuild = .distantPast
        lock.unlock()
    }

    /// 测试/调试: 缓存统计
    public func stats() -> (nodes: Int, lastBuild: Date, ageSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (cache.count, lastBuild, Date().timeIntervalSince(lastBuild))
    }
}
