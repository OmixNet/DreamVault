import XCTest
@testable import DreamEngine

/// P3-6 follow-up 评审 §4.1 修复: 把 embedding 真用起来.
/// - 矛盾预筛 topK: Prescreener 加 embedding 预筛, 候选对 cosine ≥ 阈值才走 LLM
/// - 语义边: KnowledgeGraph.semanticEdges 跨文件同主题连 embedding 边 (建议, 不改 graph)
///
/// 关键 invariant:
/// - embeddingProvider: nil (老默认) 行为跟 v0.7.0 一致 (0 退化)
/// - embeddingProvider: 注入后, topK 模式启用, 跨语言 / 跨 token 也能筛出对
/// - 评分优先级: embedding (2.0+) > token (1.0) > Adamic-Adar (0+)
/// - maxPerNode 限热门节点刷屏
final class P36FollowupTests: XCTestCase {

    // MARK: - Prescreener embedding topK 模式

    /// 1. 老路径 (embeddingProvider: nil) 行为不变
    func testPrescreener_noEmbedding_fallsBackToOld() {
        let graph = KnowledgeGraph()
        let prescreener = Prescreener(maxPairsPerNight: 50, graph: graph, embeddingProvider: nil)
        let cand = makeMemory(id: "c1", text: "SwiftUI 适合 macOS 桌面 UI")
        let exist1 = makeMemory(id: "e1", text: "SwiftUI 用于 macOS 桌面开发")  // token 重合
        let exist2 = makeMemory(id: "e2", text: "AppKit 用于 macOS 桌面开发")   // token 重合
        let result = prescreener.prescreen(candidates: [cand], against: [exist1, exist2])
        XCTAssertFalse(result.embeddingPrescreenEnabled)
        XCTAssertEqual(result.toCompare.count, 2)  // 两个 token 重合
    }

    /// 2. 注入 VariableProvider 后, embedding 模式启用
    func testPrescreener_withEmbedding_prescreenEnabled() {
        // 关键词 → 固定向量
        let provider = VariableProvider(["swiftui": [1.0, 0.0, 0.0]])
        let graph = KnowledgeGraph()
        let prescreener = Prescreener(maxPairsPerNight: 50, graph: graph, embeddingProvider: provider)
        let cand = makeMemory(id: "c1", text: "swiftui")
        let exist1 = makeMemory(id: "e1", text: "swiftui")
        let result = prescreener.prescreen(candidates: [cand], against: [exist1])
        XCTAssertTrue(result.embeddingPrescreenEnabled)
        // exact same text → cosine 1.0 → 进入候选
        XCTAssertTrue(result.toCompare.contains { $0.candidate.id == "c1" && $0.existing.id == "e1" })
    }

    /// 3. topK=2: 候选对被限到每 candidate 2 个 existing
    func testPrescreener_topKLimits() {
        // 4 个 existing 都跟 cand 高 cosine, 但 token 不重合 (避免老 token 路径补漏)
        // cand="alphatopic" (token=alphatopic), existings="betatopic"/"gammatopic"/...
        // VariableProvider: alpha→[1,0,0], beta→[1,0.1,0], gamma→[1,0.2,0], delta→[1,0.3,0]
        // cosine 都 ≈ 0.99, 老 token 不补漏 (不同 token), 走 embedding topK
        let provider = VariableProvider([
            "alphatopic": [1.0, 0.0, 0.0],
            "betatopic":  [1.0, 0.1, 0.0],
            "gammatopic": [1.0, 0.2, 0.0],
            "deltatopic": [1.0, 0.3, 0.0]
        ])
        let graph = KnowledgeGraph()
        let prescreener = Prescreener(maxPairsPerNight: 50, graph: graph, embeddingProvider: provider, embeddingTopK: 2)
        let cand = makeMemory(id: "c1", text: "alphatopic")
        let existings = [
            makeMemory(id: "e1", text: "betatopic"),
            makeMemory(id: "e2", text: "gammatopic"),
            makeMemory(id: "e3", text: "deltatopic"),
            makeMemory(id: "e4", text: "alphatopic")
        ]
        let result = prescreener.prescreen(candidates: [cand], against: existings)
        // 4 个都 cosine ≥ 0.99, 老 token 不补漏, 走 embedding topK=2 → 2 对
        XCTAssertEqual(result.toCompare.count, 2, "topK=2 应只保留 2 对 (老 token 路径不补漏)")
    }

    /// 4. threshold 0.95 过滤低 cosine 对
    func testPrescreener_thresholdFiltersLowCosine() {
        // "swiftui" → [1,0,0], "appkit" → [0,1,0] → cosine 0.0
        // threshold=0.95 → appkit 应被过滤
        let provider = VariableProvider([
            "swiftui": [1.0, 0.0, 0.0],
            "appkit": [0.0, 1.0, 0.0]
        ])
        let graph = KnowledgeGraph()
        let prescreener = Prescreener(
            maxPairsPerNight: 50, graph: graph,
            embeddingProvider: provider,
            embeddingTopK: 5,
            embeddingSimilarityThreshold: 0.95
        )
        let cand = makeMemory(id: "c1", text: "swiftui")
        let existSwiftUI = makeMemory(id: "e1", text: "swiftui")
        let existAppKit = makeMemory(id: "e2", text: "appkit")
        let result = prescreener.prescreen(candidates: [cand], against: [existSwiftUI, existAppKit])
        // 只有 swiftui (cosine 1.0 ≥ 0.95) 进入; appkit (0.0 < 0.95) 过滤
        XCTAssertTrue(result.toCompare.contains { $0.existing.id == "e1" })
        XCTAssertFalse(result.toCompare.contains { $0.existing.id == "e2" })
    }

    /// 5. 跨语言 / 跨 token 场景: 老 token 路径漏掉, embedding 路径能筛
    func testPrescreener_embeddingCatchesTokenMiss() {
        // "机器学习" vs "machine learning" → token 不重合 (字符级) 但语义相关
        // VariableProvider 模拟: 给两个不同关键词分配同向近向量
        let provider = VariableProvider([
            "机器学习": [1.0, 0.5, 0.0],
            "machinelearning": [0.95, 0.5, 0.0],  // cosine ≈ 0.99
        ])
        let graph = KnowledgeGraph()
        let prescreener = Prescreener(maxPairsPerNight: 50, graph: graph, embeddingProvider: provider)
        let cand = makeMemory(id: "c1", text: "机器学习")
        let exist = makeMemory(id: "e1", text: "machinelearning")
        let result = prescreener.prescreen(candidates: [cand], against: [exist])
        // 老 token 路径漏 (字符不重合), embedding 路径捕到
        XCTAssertTrue(result.toCompare.contains { $0.existing.id == "e1" }, "embedding 应捕到跨语言相关对")
    }

    // MARK: - KnowledgeGraph.semanticEdges

    /// 6. 跨文件同主题连边
    func testSemanticEdges_crossFileTopics() {
        // "swiftui" 跟 "swiftui" 完全相似, cosine 1.0
        let provider = VariableProvider([
            "swiftui": [1.0, 0.0, 0.0],
            "uikit": [0.0, 1.0, 0.0]
        ])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3"] { graph.addNode(id) }
        let texts: [String: String] = [
            "m1": "swiftui",
            "m2": "swiftui",
            "m3": "uikit"
        ]
        let edges = graph.semanticEdges(provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts)
        // m1 跟 m2 cosine 1.0, 跟 m3 cosine 0.0
        // 注意: Set 迭代顺序非确定, 边可能 (m1, m2) 或 (m2, m1)
        let hasM1M2 = edges.contains { pair in
            let (a, b, score) = pair
            return ((a == "m1" && b == "m2") || (a == "m2" && b == "m1")) && score > 0.9
        }
        XCTAssertTrue(hasM1M2, "应包含 m1-m2 边 (cosine 1.0)")
        let hasM1M3 = edges.contains { pair in
            let (a, b, _) = pair
            return (a == "m1" && b == "m3") || (a == "m3" && b == "m1")
        }
        XCTAssertFalse(hasM1M3, "不应包含 m1-m3 边 (cosine 0)")
    }

    /// 7. maxPerNode 限热门节点
    func testSemanticEdges_maxPerNodeLimit() {
        // 一个中心节点 m1 跟 5 个子节点都高 cosine, maxPerNode=2 → 只留 2
        let provider = VariableProvider(["topic": [1.0, 0.0, 0.0]])
        var graph = KnowledgeGraph()
        for id in ["m1", "m2", "m3", "m4", "m5"] { graph.addNode(id) }
        let texts: [String: String] = [
            "m1": "topic", "m2": "topic", "m3": "topic", "m4": "topic", "m5": "topic"
        ]
        let edges = graph.semanticEdges(provider: provider, threshold: 0.85, maxPerNode: 2, texts: texts)
        // m1 应只连 2 个
        let m1Edges = edges.filter { $0.a == "m1" || $0.b == "m1" }
        XCTAssertLessThanOrEqual(m1Edges.count, 2)
    }

    /// 8. 已有边跳过 (跟"来源重叠"边互补)
    func testSemanticEdges_skipExistingEdges() {
        let provider = VariableProvider(["swiftui": [1.0, 0.0, 0.0]])
        var graph = KnowledgeGraph()
        graph.addEdge("m1", "m2")  // 已有边
        let texts: [String: String] = ["m1": "swiftui", "m2": "swiftui"]
        let edges = graph.semanticEdges(provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts)
        XCTAssertTrue(edges.isEmpty, "已有边应跳过")
    }

    /// 9. threshold 过滤
    func testSemanticEdges_thresholdFilters() {
        let provider = VariableProvider([
            "a": [1.0, 0.0, 0.0],
            "b": [0.0, 1.0, 0.0]
        ])
        let graph = KnowledgeGraph()
        let texts: [String: String] = ["m1": "a", "m2": "b"]  // cosine 0
        let edges = graph.semanticEdges(provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts)
        XCTAssertTrue(edges.isEmpty, "cosine 0 应被 threshold 0.85 过滤")
    }

    /// 10. 不可用 provider 返空 (provider.embed 返 nil)
    func testSemanticEdges_unavailableProvider() {
        // 不可用 provider: StaticEmbeddingProvider.returnNil = true
        let provider = StaticEmbeddingProvider(dimension: 3, vector: [1, 0, 0], returnNil: true)
        let graph = KnowledgeGraph()
        let texts: [String: String] = ["m1": "swiftui", "m2": "swiftui"]
        let edges = graph.semanticEdges(provider: provider, threshold: 0.85, maxPerNode: 5, texts: texts)
        XCTAssertTrue(edges.isEmpty, "provider 不可用应返空")
    }

    // MARK: - ContradictionDetector 集成

    /// 11. ContradictionDetector 接受 embeddingProvider (向后兼容默认 nil)
    func testContradictionDetector_initWithEmbedding() {
        let provider = VariableProvider(["x": [1.0, 0.0, 0.0]])
        let detector = ContradictionDetector(
            llm: MockLLMProvider(),
            maxPairsPerNight: 50,
            graph: KnowledgeGraph(),
            embeddingProvider: provider,
            embeddingTopK: 3,
            embeddingSimilarityThreshold: 0.5
        )
        XCTAssertNotNil(detector.prescreener.embeddingProvider)
    }

    /// 12. embedding 模式跑 link: 预筛结果 embeddingPrescreenEnabled=true
    func testContradictionDetector_link_usesEmbeddingPrescreen() async throws {
        let provider = VariableProvider(["swiftui": [1.0, 0.0, 0.0]])
        let stubLLM = MockLLMProvider { _, _ in "OK" }  // 不矛盾
        var detector = ContradictionDetector(
            llm: stubLLM,
            maxPairsPerNight: 50,
            graph: KnowledgeGraph(),
            embeddingProvider: provider
        )
        let cand = makeMemory(id: "c1", text: "swiftui")
        let exist = makeMemory(id: "e1", text: "swiftui")
        let (c, e) = try await detector.link(candidates: [cand], against: [exist])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(e.count, 1)
        XCTAssertNotNil(detector.lastPrescreenResult)
        XCTAssertTrue(detector.lastPrescreenResult?.embeddingPrescreenEnabled ?? false)
    }

    // MARK: - DreamConfig 集成

    /// 13. DreamConfig 加 embeddingProvider 字段
    func testDreamConfig_embeddingProvider() {
        let provider = VariableProvider(["x": [1.0, 0.0, 0.0]])
        let config = DreamConfig(embeddingProvider: provider, embeddingTopK: 3)
        XCTAssertNotNil(config.embeddingProvider)
        XCTAssertEqual(config.embeddingTopK, 3)
    }

    /// 14. P3-6 follow-up (v0.7.2): productionDefault 默认开 NLEmbedding (macOS 12+)
    /// - dimension > 0 → CachedEmbeddingProvider
    /// - dimension == 0 (不可用) → nil (降级走老路径)
    /// v0.7.0 老测试 (P36FollowupTests.testDreamConfig_productionDefaultNoEmbedding)
    /// 改成这个 invariant 兼容: 不可用时仍 nil, 可用时 NOT nil.
    func testDreamConfig_productionDefaultEmbeddingPolicy() {
        if let provider = DreamConfig.productionDefault.embeddingProvider {
            // 可用: 应是 CachedEmbeddingProvider 包装的 NLEmbeddingProvider
            XCTAssertGreaterThan(provider.dimension, 0, "可用 provider dimension 应 > 0")
        }
        // 不可用时 nil 也合法 (macOS 11- / 系统语言不支持)
    }

    // MARK: - Helper

    private func makeMemory(id: String, text: String) -> Memory {
        return Memory(
            id: id, text: text,
            sources: [SourceRef(file: "raw/\(id).md", line: 1, excerpt: text)],
            status: .durable, createdAt: Date(), lastAccess: Date(),
            reinforceCount: 0, inboundLinks: 0, contradicts: [],
            decayClass: .normal, kind: .entity, relatedTo: []
        )
    }
}
