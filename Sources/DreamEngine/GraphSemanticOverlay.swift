import Foundation

/// P2-2 follow-up: KnowledgeGraph.semanticEdges 跨文件同主题社区.
/// P3-6 follow-up 留的 v0.7.x 尾巴 — 让 P2-2 GraphRenderer 能真用上 semantic edges.
///
/// 设计: **纯函数 + 数据结构**, 不修改 graph 本身, 不渲染 UI.
/// 调用方 (P2-2 GraphRenderer) 拿到 enhance() 结果自己决定加边 / 调透明度 / 调色.
public enum GraphSemanticOverlay {
    /// 语义邻居表: nodeId → 跟它语义相关的其他 nodeIds (cosine ≥ threshold)
    public struct SemanticNeighbors {
        /// 节点 → 邻居列表 (按 cosine 降序)
        public let neighbors: [String: [(id: String, score: Double)]]
        /// 阈值
        public let threshold: Double
        /// 每节点 max 邻居数
        public let maxPerNode: Int
        /// 实际启用了 embedding provider (false = 没跑语义增强)
        public let enabled: Bool

        public var totalEdgeCount: Int { neighbors.values.reduce(0) { $0 + $1.count } }
        public var nodesWithSemanticNeighbors: Int { neighbors.count }
    }

    /// 调 KnowledgeGraph.semanticEdges 算建议边, 转成 SemanticNeighbors 包装.
    /// - Parameters:
    ///   - graph: 原 KnowledgeGraph (只读, 不修改)
    ///   - provider: EmbeddingProvider (nil → 不启用, 返 disabled 包装)
    ///   - threshold: cosine 阈值 (默认 0.85, 跟 EmbeddingMerge.cosineMergeThreshold 对齐)
    ///   - maxPerNode: 每节点最多返 maxPerNode 邻居 (默认 5)
    ///   - texts: 节点 id → 文本 (跟 semanticEdges 同款)
    public static func enhance(
        graph: KnowledgeGraph,
        provider: EmbeddingProvider?,
        threshold: Double = 0.85,
        maxPerNode: Int = 5,
        texts: [String: String]
    ) -> SemanticNeighbors {
        guard let provider = provider else {
            return SemanticNeighbors(
                neighbors: [:], threshold: threshold,
                maxPerNode: maxPerNode, enabled: false
            )
        }
        let edges = graph.semanticEdges(
            provider: provider, threshold: threshold,
            maxPerNode: maxPerNode, texts: texts
        )
        // 按节点聚合 (a, b, score) → [a: [(b, score)], b: [(a, score)]]
        var byNode: [String: [(id: String, score: Double)]] = [:]
        for (a, b, score) in edges {
            byNode[a, default: []].append((b, score))
            byNode[b, default: []].append((a, score))
        }
        // 按 cosine 降序排序
        for (k, v) in byNode {
            byNode[k] = v.sorted { $0.score > $1.score }
        }
        return SemanticNeighbors(
            neighbors: byNode, threshold: threshold,
            maxPerNode: maxPerNode, enabled: true
        )
    }

    /// 找"语义社区": 把 semantic edges 当无向图, BFS 找连通分量.
    /// 同一社区内的节点共享一个 communityId (整数, BFS 访问顺序).
    /// 孤立节点 (无 semantic 邻居) → 各自独立 community.
    public static func communities(
        from neighbors: SemanticNeighbors
    ) -> [String: Int] {
        var visited: Set<String> = []
        var community: [String: Int] = [:]
        var nextId = 0
        // 收集所有候选节点: 有邻居的 + 自身 (孤立节点)
        var allNodes: Set<String> = Set(neighbors.neighbors.keys)
        for (a, list) in neighbors.neighbors {
            for (b, _) in list { allNodes.insert(b) }
        }
        for node in allNodes {
            if visited.contains(node) { continue }
            // BFS
            var queue: [String] = [node]
            visited.insert(node)
            while !queue.isEmpty {
                let cur = queue.removeFirst()
                community[cur] = nextId
                for (neighbor, _) in neighbors.neighbors[cur] ?? [] {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        queue.append(neighbor)
                    }
                }
            }
            nextId += 1
        }
        return community
    }

    /// 合并 Adamic-Adar 邻居 + semantic 邻居 → 增强的图.
    /// 调用方拿到 var graph = ...; GraphSemanticOverlay.mergeEdges(...) 写回.
    /// 这是**纯函数变体** — 不修改入参 graph, 返新 graph (value type).
    ///
    /// - Parameters:
    ///   - graph: 原 graph
    ///   - neighbors: 语义邻居
    ///   - includeSemantic: false = 仅返原 graph (用户切"关语义"开关)
    /// - Returns: 新 KnowledgeGraph (已 addEdge semantic neighbors)
    public static func merged(
        graph: KnowledgeGraph,
        neighbors: SemanticNeighbors,
        includeSemantic: Bool = true
    ) -> KnowledgeGraph {
        guard includeSemantic, neighbors.enabled else { return graph }
        var out = graph
        for (a, list) in neighbors.neighbors {
            for (b, _) in list {
                out.addEdge(a, b)
            }
        }
        return out
    }
}
