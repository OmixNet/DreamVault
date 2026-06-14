import Foundation

/// 原生轻量知识图谱：无向图 + Adamic-Adar 关联打分。
/// 参考 llm_wiki 的"4 信号图谱"思想（仅思想，原生重写），第一版只实现
/// Adamic-Adar 一个信号：score(u,v) = Σ over 共同邻居 w of 1/log(degree(w))。
/// 共同邻居越多、越"专属"（度数越低），u 与 v 的关联越强。
///
/// 节点 id 通常是 Memory.id 或 wiki 页名；边的来源可以是共享 source 文件、
/// 显式 [[wikilink]] 等，由调用方决定。
public struct KnowledgeGraph: Equatable {
    /// 邻接表。节点可孤立存在（值为空集合）。
    public private(set) var adjacency: [String: Set<String>] = [:]

    public init() {}

    /// 便捷构造：从一批记忆建图——共享同一 raw 源文件的记忆之间连边。
    /// 这是 dream 场景里最自然的关联信号（来源重叠）。
    public init(memories: [Memory]) {
        for m in memories { addNode(m.id) }
        // 按源文件分桶，同桶内两两连边
        var bySource: [String: [String]] = [:]
        for m in memories {
            for f in Set(m.sources.map { $0.file }) {
                bySource[f, default: []].append(m.id)
            }
        }
        for (_, ids) in bySource where ids.count > 1 {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    addEdge(ids[i], ids[j])
                }
            }
        }
    }

    public var nodes: Set<String> { Set(adjacency.keys) }

    public mutating func addNode(_ id: String) {
        if adjacency[id] == nil { adjacency[id] = [] }
    }

    /// 无向边；自环忽略（自己和自己关联无意义）
    public mutating func addEdge(_ a: String, _ b: String) {
        guard a != b else { return }
        adjacency[a, default: []].insert(b)
        adjacency[b, default: []].insert(a)
    }

    public func neighbors(of id: String) -> Set<String> {
        adjacency[id] ?? []
    }

    public func degree(of id: String) -> Int {
        adjacency[id]?.count ?? 0
    }

    /// Adamic-Adar 关联分（REFERENCE_SPEC 附录标准公式）：
    /// score(u,v) = Σ over 共同邻居 w of 1/log(degree(w))
    /// 注：共同邻居 w 至少同时连着 u 和 v，degree(w) ≥ 2，log 恒为正，无除零风险。
    public func adamicAdar(_ u: String, _ v: String) -> Double {
        guard u != v else { return 0 }
        let common = neighbors(of: u).intersection(neighbors(of: v))
        return common.reduce(0) { acc, w in
            acc + 1.0 / log(Double(degree(of: w)))
        }
    }

    /// 与 id 关联最强的前 limit 个节点（按 Adamic-Adar 降序，分数 0 的不返回）。
    /// 用于 Persister 在 wiki 页生成"相关 [[links]]"。
    /// 注意：用 for 循环而非链式闭包 ——Swift 6.3 类型推导拒绝过深的链式表达式。
    public func topRelated(to id: String, limit: Int = 5) -> [(id: String, score: Double)] {
        var scored: [(id: String, score: Double)] = []
        scored.reserveCapacity(nodes.count)
        for other in nodes where other != id {
            let s = adamicAdar(id, other)
            if s > 0 { scored.append((id: other, score: s)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        if scored.count > limit { scored.removeLast(scored.count - limit) }
        return scored
    }

    /// P0 致命修复 (缺陷报告 §1.1): 跳数限制剪枝版本.
    /// 老 topRelated O(N) — N=10000 时 30s 卡顿. 改 maxHops 剪枝 → 跳数内节点 O(N) 平均, 跳数外不访问.
    /// - maxHops: nil = 走老逻辑 (无剪枝, 向后兼容). 1/2 推荐值.
    ///   - 1: 仅直接邻居 (O(degree), <1ms for N=10000 稀疏图)
    ///   - 2: 邻居的邻居 (含 1 跳, 实测 O(N) 平均, 1-3s for N=10000 稀疏图)
    ///   - 3+: 接近老逻辑, 收益小
    /// - 语义: 仅在跳数内的节点参与 Adamic-Adar 计算, 跳数外不计算.
    ///   Adamic-Adar 共同邻居定义不变, 只是 v 必须 ≤ maxHops 跳.
    public func topRelated(to id: String, limit: Int = 5, maxHops: Int?) -> [(id: String, score: Double)] {
        guard let maxHops = maxHops else {
            return topRelated(to: id, limit: limit)  // 老路径, 向后兼容
        }
        guard maxHops >= 1 else { return [] }
        // 1) BFS 算 ≤ maxHops 跳的节点 (不含 id 自身)
        let reachable = bfsReachable(from: id, maxHops: maxHops)
        // 2) 仅对 reachable 内节点算 Adamic-Adar
        var scored: [(id: String, score: Double)] = []
        scored.reserveCapacity(reachable.count)
        for other in reachable where other != id {
            let s = adamicAdar(id, other)
            if s > 0 { scored.append((id: other, score: s)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        if scored.count > limit { scored.removeLast(scored.count - limit) }
        return scored
    }

    /// P0 内部辅助: BFS 找 ≤ maxHops 跳的所有节点 (含 id 自身).
    private func bfsReachable(from id: String, maxHops: Int) -> Set<String> {
        var visited: Set<String> = [id]
        var frontier: Set<String> = [id]
        for _ in 0..<maxHops {
            var next: Set<String> = []
            for node in frontier {
                for neighbor in neighbors(of: node) where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    next.insert(neighbor)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return visited
    }

    // MARK: - P3-6 follow-up: 语义边 (embedding cosine 跨文件同主题)

    /// 算"建议加的语义边"：跨文件同主题的两节点，embedding cosine ≥ threshold.
    /// **不修改 graph 本身** (immutable); 返回建议边列表, 调用方决定是否 addEdge.
    ///
    /// 为什么纯函数:
    /// - KnowledgeGraph 是 value type, 改它需要 var copy (调用方持有); 这是有意的设计
    /// - semanticEdges 是"建议", 跟图谱已有"来源"边 (共享 source file) 是独立信号
    /// - 调用方 (Persister / GraphRenderer) 可选择性应用
    ///
    /// - Parameters:
    ///   - provider: EmbeddingProvider (走 NLEmbeddingProvider 或 cache/static)
    ///   - threshold: cosine 阈值 (默认 0.85, 跟 EmbeddingMerge.cosineMergeThreshold 对齐)
    ///   - maxPerNode: 每节点最多返 maxPerNode 条建议边 (避免热门节点刷屏)
    ///   - texts: 节点 id → 文本 映射 (需要外部传入, KnowledgeGraph 不知道 memory.text)
    /// - Returns: [(a, b, score)] 排序按 score 降序
    public func semanticEdges(
        provider: EmbeddingProvider,
        threshold: Double = 0.85,
        maxPerNode: Int = 5,
        texts: [String: String]
    ) -> [(a: String, b: String, score: Double)] {
        // 1. 批量算 embedding
        var embeddings: [String: [Double]] = [:]
        for id in nodes {
            if let text = texts[id], let v = provider.embed(text) {
                embeddings[id] = v
            }
        }
        guard embeddings.count >= 2 else { return [] }

        // 2. 两两配对算 cosine
        let ids = Array(embeddings.keys)
        var allPairs: [(a: String, b: String, score: Double)] = []
        allPairs.reserveCapacity(ids.count * (ids.count - 1) / 2)
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let a = ids[i], b = ids[j]
                let av = embeddings[a]!
                let bv = embeddings[b]!
                // 跳过已有边 (来源重叠的边已经在 graph 里)
                if neighbors(of: a).contains(b) { continue }
                let sim = EmbeddingMath.cosineSimilarity(av, bv)
                if sim >= threshold {
                    allPairs.append((a, b, sim))
                }
            }
        }
        // 3. 全局排序 + 每节点限 maxPerNode
        allPairs.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.a < rhs.a }
            return lhs.score > rhs.score
        }
        var perNodeCount: [String: Int] = [:]
        var out: [(a: String, b: String, score: Double)] = []
        for pair in allPairs {
            let ca = perNodeCount[pair.a, default: 0]
            let cb = perNodeCount[pair.b, default: 0]
            if ca >= maxPerNode || cb >= maxPerNode { continue }
            out.append(pair)
            perNodeCount[pair.a] = ca + 1
            perNodeCount[pair.b] = cb + 1
        }
        return out
    }
}
