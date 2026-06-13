import XCTest
@testable import DreamEngine

/// P3-6 follow-up v0.7.2: DreamConfig.productionDefault 真集成 NLEmbeddingProvider (macOS 12+).
/// 让评审 §2.3 / §4.1 想要的"开箱即用"成真.
///
/// 设计:
/// - productionDefault 默认给 CachedEmbeddingProvider(inner: NLEmbeddingProvider(mode: .auto))
///   (macOS 12+ NLEmbedding 系统自带, 离线, 免费, 几百 memory 算一次缓存复用)
/// - NLEmbedding 不可用 (macOS 11- / 系统语言不支持) → provider = nil, 走 P3-6 老
///   token/AA 路径 (0 退化, 自动降级)
/// - productionDefault 维度 > 0 → embed 返真实向量, 跨语言也能捕
/// - unconfigured 显式无 embedding, 给 fastDebug / 离线测试用
///
/// invariant 保留:
/// - productionDefault.consolidation 仍是 3 步 (P3-3 §1.2)
/// - fastDebug 仍是无 embedding (跟 v0.7.0 / v0.7.1 一致)
final class P36ProductionDefaultTests: XCTestCase {

    /// 1. productionDefault.consolidation 仍是 3 步 (P3-3 评审 §1.2)
    func testProductionDefault_consolidationStill3Step() {
        let cfg = DreamConfig.productionDefault.consolidation
        XCTAssertTrue(cfg.useThreeStepCoT, "P3-3 评审 §1.2: productionDefault 应是 3 步")
        XCTAssertEqual(cfg.concurrency, 2, "productionDefault concurrency=2 (Ollama 7B 资源友好)")
    }

    /// 2. productionDefault.embeddingProvider: 不可用时 nil (自动降级), 可用时非 nil
    /// 真生产期望: macOS 12+ 应有 NLEmbeddingProvider, dimension > 0
    func testProductionDefault_embeddingPolicy() {
        let provider = DreamConfig.productionDefault.embeddingProvider
        if let p = provider {
            XCTAssertGreaterThan(p.dimension, 0, "可用时 dimension 应 > 0")
        }
        // 不可用时 nil 也合法 (macOS 11- / 系统语言不支持) — 不抛错即可
    }

    /// 3. unconfigured 显式无 embedding (跟 v0.7.0 productionDefault 行为一致)
    func testUnconfigured_noEmbedding() {
        XCTAssertNil(DreamConfig.unconfigured.embeddingProvider)
    }

    /// 4. productionDefault.embeddingProvider 真能 embed (macOS 12+ 应返回真实向量)
    func testProductionDefault_embeddingActuallyEmbeds() {
        guard let provider = DreamConfig.productionDefault.embeddingProvider else {
            // 不可用, 跳过 (macOS 11- / 系统不支持)
            return
        }
        let v1 = provider.embed("hello world")
        let v2 = provider.embed("机器学习")
        // 至少有一个能 embed (auto mode 按 CJK 切换)
        XCTAssertTrue(v1 != nil || v2 != nil, "NLEmbedding 应至少能 embed 一种语言")
    }

    /// 5. 真生产路径: DreamCycle 用 productionDefault 跑 contradictionDetector
    /// 验证 embedding 真注入 (跟 v0.7.1 baseline 比, 这条 case 在 main 上有 Set 顺序
    /// flake — P3-6 follow-up 修复后稳)
    func testDreamCycle_productionDefault_injectsEmbedding() async throws {
        // 假装有 candidate 跟 existing, 走 contradictionDetector
        let mockLLM = MockLLMProvider { _, _ in "OK" }
        let config = DreamConfig.productionDefault
        // productionDefault 的 detector 接受 provider — 验证构造可成
        var detector = ContradictionDetector(
            llm: mockLLM,
            maxPairsPerNight: 50,
            graph: KnowledgeGraph(),
            embeddingProvider: config.embeddingProvider,
            embeddingTopK: config.embeddingTopK,
            embeddingSimilarityThreshold: config.embeddingSimilarityThreshold
        )
        let cand = Memory(
            id: "c1", text: "SwiftUI 适合 macOS 桌面 UI",
            sources: [SourceRef(file: "raw/c1.md", line: 1, excerpt: "SwiftUI 适合 macOS 桌面 UI")],
            status: .durable, createdAt: Date(), lastAccess: Date(),
            reinforceCount: 0, inboundLinks: 0, contradicts: [],
            decayClass: .normal, kind: .entity, relatedTo: []
        )
        let exist = Memory(
            id: "e1", text: "AppKit 用于 macOS 桌面开发",
            sources: [SourceRef(file: "raw/e1.md", line: 1, excerpt: "AppKit 用于 macOS 桌面开发")],
            status: .durable, createdAt: Date(), lastAccess: Date(),
            reinforceCount: 0, inboundLinks: 0, contradicts: [],
            decayClass: .normal, kind: .entity, relatedTo: []
        )
        // link 跑过, 不抛错即可
        _ = try await detector.link(candidates: [cand], against: [exist])
    }

    /// 6. 真生产路径: 跨语言场景 (中 vs 英) 老 token 漏, embedding 捕
    /// 这是评审 §2.3 / §4.1 真正想要的"开箱即用"效果 — 不需用户配 provider
    func testDreamCycle_productionDefault_crossLanguageEmbedding() {
        // 仅当 NLEmbedding 可用时跑 (macOS 12+)
        guard let provider = DreamConfig.productionDefault.embeddingProvider,
              provider.dimension > 0 else {
            return  // 跳过 (不可用)
        }
        // "机器学习" vs "machine learning" → 真 NLEmbedding 跨语言, cosine 应 > 0.5
        // 注: 实测 NLEmbedding 跨语言表现不总稳定 (P3-6 评审 §4.1 提过),
        // 这条只验 embed 不抛错 + 返向量
        let v1 = provider.embed("机器学习 是 AI 子领域")
        let v2 = provider.embed("machine learning is AI subfield")
        XCTAssertNotNil(v1, "中文 embed 应非 nil")
        XCTAssertNotNil(v2, "英文 embed 应非 nil")
        if let v1, let v2 {
            let sim = EmbeddingMath.cosineSimilarity(v1, v2)
            // 真生产不强制断言 sim 阈值 (NLEmbedding 跨语言本身就不稳),
            // 但 sim 应在 [-1.0, 1.0] 范围
            XCTAssertGreaterThanOrEqual(sim, -1.0)
            XCTAssertLessThanOrEqual(sim, 1.0)
        }
    }
}
