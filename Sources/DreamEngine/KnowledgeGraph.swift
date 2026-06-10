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
    public func topRelated(to id: String, limit: Int = 5) -> [(id: String, score: Double)] {
        nodes
            .filter { $0 != id }
            .map { (id: $0, score: adamicAdar(id, $0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
