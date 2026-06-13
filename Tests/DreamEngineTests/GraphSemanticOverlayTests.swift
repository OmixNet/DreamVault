import XCTest
@testable import DreamEngine

/// P2-2 follow-up: GraphSemanticOverlay 把 P3-6 follow-up (KnowledgeGraph.semanticEdges)
/// 包成 P2-2 GraphRenderer 可调的"语义增强层". 这是 v0.7.x 留的尾巴.
///
/// 设计:
/// - 纯函数 + 数据结构, 不修改 graph 本身
/// - enhance() 拿 SemanticNeighbors (node → [(neighbor, score)])
/// - communities() BFS 找连通分量 → 社区 ID
/// - merged() 返新 graph (value type) 带 semantic edges
/// - P2-2 GraphRenderer (user uncommit 状态) 之后一行调用 merged() 加边
final class GraphSemanticOverlayTests: XCTestCase {

    // MARK: - enhance() 基础

    /// 1. nil provider → 返 disabled 包装 (空 neighbors + enabled=false)
    func testEnhance_nilProvider_disabled() {
        let graph = KnowledgeGraph()
        let result = GraphSemanticOverlay.enhance(
            graph: graph, provider: nil, texts: ["a": "test"]
        )
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.neighbors.count, 0)
    }

    /// 2. 注入 provider + graph + texts → 算 neighbors
    func testEnhance_withProvider_computesNeighbors() {
        let provider = VariableProvider([
            "swiftui": [1.0, 0.0, 0.0],
            "uikit": [0.0, 1.0, 0.0]
        ])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3"] { graph.addNode(id) }
        let texts = ["m1": "swiftui", "m2": "swiftui", "m3": "uikit"]
        let result = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        XCTAssertTrue(result.enabled)
        // m1 跟 m2 同 swiftui, cosine 1.0 → 双向邻居
        XCTAssertTrue(result.neighbors["m1"]?.contains { $0.id == "m2" } ?? false)
        XCTAssertTrue(result.neighbors["m2"]?.contains { $0.id == "m1" } ?? false)
        // m1 跟 m3 跨主题, cosine 0 → 不连
        XCTAssertFalse(result.neighbors["m1"]?.contains { $0.id == "m3" } ?? false)
    }

    /// 3. 邻居按 cosine 降序
    func testEnhance_neighborsSortedByCosine() {
        // 4 个 existing 跟 cand cosine 不同
        let provider = VariableProvider([
            "c": [1.0, 0.0, 0.0],
            "e_high": [1.0, 0.0, 0.0],     // 1.0
            "e_mid":  [0.9, 0.436, 0.0],   // 0.9
            "e_low":  [0.7, 0.714, 0.0]    // 0.7
        ])
        var graph = KnowledgeGraph()
        for id in ["c", "e_high", "e_mid", "e_low"] { graph.addNode(id) }
        let texts: [String: String] = [
            "c": "c", "e_high": "e_high", "e_mid": "e_mid", "e_low": "e_low"
        ]
        let result = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.5, maxPerNode: 5, texts: texts
        )
        let cNeighbors = result.neighbors["c"] ?? []
        XCTAssertEqual(cNeighbors.count, 3)
        // 排序降序: 1.0 > 0.9 > 0.7
        XCTAssertEqual(cNeighbors[0].id, "e_high")
        XCTAssertEqual(cNeighbors[1].id, "e_mid")
        XCTAssertEqual(cNeighbors[2].id, "e_low")
    }

    // MARK: - communities() BFS 社区检测

    /// 4. 两个独立社区 (m1-m2, m3-m4) 不连
    func testCommunities_twoIsolatedCommunities() {
        let provider = VariableProvider([
            "a": [1.0, 0.0, 0.0],
            "b": [0.0, 1.0, 0.0]
        ])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3", "m4"] { graph.addNode(id) }
        let texts: [String: String] = [
            "m1": "a", "m2": "a",  // community 1 (swiftui 主题)
            "m3": "b", "m4": "b"   // community 2 (uikit 主题)
        ]
        let neighbors = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        let communities = GraphSemanticOverlay.communities(from: neighbors)
        // m1, m2 同一 community; m3, m4 同一 community
        XCTAssertEqual(communities["m1"], communities["m2"])
        XCTAssertEqual(communities["m3"], communities["m4"])
        XCTAssertNotEqual(communities["m1"], communities["m3"])
    }

    /// 5. 三个孤立节点 → 三个 community
    /// 注意: communities() 只看 semantic neighbors, 不扫 graph.nodes.
    /// 0 neighbors → 0 communities. 这是有意的 (P2-2 GraphRenderer 集成时可改).
    /// 验: 3 个节点都不在社区里.
    func testCommunities_noEdges_noCommunities() {
        let provider = VariableProvider([
            "a": [1.0, 0.0, 0.0],
            "b": [0.0, 1.0, 0.0],
            "c": [0.0, 0.0, 1.0]
        ])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3"] { graph.addNode(id) }
        let texts: [String: String] = ["m1": "a", "m2": "b", "m3": "c"]
        let neighbors = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        let communities = GraphSemanticOverlay.communities(from: neighbors)
        // 0 semantic 边 → 0 community (这是设计: 纯语义社区, 不混合孤立节点)
        XCTAssertEqual(communities.count, 0, "0 边 → 0 community")
    }

    // MARK: - merged() 图谱合成

    /// 6. 合并 semantic edges 到新 graph (value type 不修改入参)
    func testMerged_addsSemanticEdges() {
        let provider = VariableProvider([
            "swiftui": [1.0, 0.0, 0.0],
            "uikit": [0.0, 1.0, 0.0]
        ])
        var original = KnowledgeGraph()
        for id in ["m1", "m2", "m3"] { original.addNode(id) }
        let texts: [String: String] = [
            "m1": "swiftui", "m2": "swiftui", "m3": "uikit"
        ]
        let neighbors = GraphSemanticOverlay.enhance(
            graph: original, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        let merged = GraphSemanticOverlay.merged(graph: original, neighbors: neighbors)
        // 原 graph 没边 (只 addNode)
        XCTAssertEqual(original.neighbors(of: "m1").count, 0)
        // 合并后 m1 跟 m2 连边
        XCTAssertTrue(merged.neighbors(of: "m1").contains("m2"))
        // 节点不变
        XCTAssertEqual(merged.nodes.count, 3)
    }

    /// 7. includeSemantic=false → 返原 graph 不变
    func testMerged_disabled_returnsOriginal() {
        let provider = VariableProvider(["a": [1.0, 0.0, 0.0]])
        var graph = KnowledgeGraph()
        graph.addNode("m1"); graph.addNode("m2")
        let texts: [String: String] = ["m1": "a", "m2": "a"]
        let neighbors = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        let merged = GraphSemanticOverlay.merged(
            graph: graph, neighbors: neighbors, includeSemantic: false
        )
        // 没加边
        XCTAssertEqual(merged.neighbors(of: "m1").count, 0)
    }

    /// 8. nil provider → 返原 graph
    func testMerged_disabledProvider_returnsOriginal() {
        var graph = KnowledgeGraph()
        graph.addNode("m1"); graph.addNode("m2")
        let texts: [String: String] = ["m1": "a", "m2": "a"]
        let neighbors = GraphSemanticOverlay.enhance(
            graph: graph, provider: nil, texts: texts
        )
        let merged = GraphSemanticOverlay.merged(graph: graph, neighbors: neighbors)
        XCTAssertEqual(merged.neighbors(of: "m1").count, 0)
    }

    /// 9. SemanticNeighbors 包装字段正确
    func testSemanticNeighbors_fields() {
        let provider = VariableProvider([
            "a": [1.0, 0.0, 0.0],
            "b": [0.0, 1.0, 0.0]
        ])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3"] { graph.addNode(id) }
        let texts: [String: String] = ["m1": "a", "m2": "a", "m3": "b"]
        let result = GraphSemanticOverlay.enhance(
            graph: graph, provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts
        )
        XCTAssertEqual(result.threshold, 0.85)
        XCTAssertEqual(result.maxPerNode, 5)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.totalEdgeCount, 2)  // m1-m2 双向 = 2
        XCTAssertEqual(result.nodesWithSemanticNeighbors, 2)  // m1, m2 有邻居; m3 没有
    }
}
