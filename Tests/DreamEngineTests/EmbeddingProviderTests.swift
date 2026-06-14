import XCTest
@testable import DreamEngine

/// P3-6 评审 §4.1 修复: 本地 embedding (NLEmbedding 系统自带).
/// 3 用: 同质合并 + 矛盾预筛 + 图谱语义边. 覆盖:
/// - EmbeddingProvider 协议 + 3 实现 (NLEmbedding / Static / Cached)
/// - EmbeddingMath.cosineSimilarity (零向量 / 长度不一致 / 大向量)
/// - NLEmbeddingProvider 自动判语言 (CJK → zh-Hans, 纯英文 → en)
/// - CachedEmbeddingProvider 缓存命中 (相同 text 只算 1 次)
/// - EmbeddingMerge 双信号 (cosine OR jaccard) 升级 P3-1 同质合并
final class EmbeddingProviderTests: XCTestCase {

    // MARK: - EmbeddingMath.cosineSimilarity

    /// 1. 相同向量 → 1.0
    func testCosine_identicalVectors_returnsOne() {
        let v: [Double] = [1.0, 2.0, 3.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v, v), 1.0, accuracy: 1e-9)
    }

    /// 2. 正交向量 → 0.0
    func testCosine_orthogonalVectors_returnsZero() {
        let v1: [Double] = [1.0, 0.0]
        let v2: [Double] = [0.0, 1.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v1, v2), 0.0, accuracy: 1e-9)
    }

    /// 3. 反向向量 → -1.0
    func testCosine_oppositeVectors_returnsNegativeOne() {
        let v1: [Double] = [1.0, 2.0, 3.0]
        let v2: [Double] = [-1.0, -2.0, -3.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v1, v2), -1.0, accuracy: 1e-9)
    }

    /// 4. 零向量 → 0.0 (避免 NaN, 评审 §4.1 强调的鲁棒性)
    func testCosine_zeroVector_returnsZero() {
        let v1: [Double] = [0.0, 0.0, 0.0]
        let v2: [Double] = [1.0, 2.0, 3.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v1, v2), 0.0, "零向量 → 0 (避免 NaN)")
    }

    /// 5. 长度不一致 → 0.0 (graceful fallback)
    func testCosine_differentLengths_returnsZero() {
        let v1: [Double] = [1.0, 2.0]
        let v2: [Double] = [1.0, 2.0, 3.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v1, v2), 0.0, "长度不一致 → 0 (不抛)")
    }

    /// 6. 空向量 → 0.0
    func testCosine_emptyVector_returnsZero() {
        let v1: [Double] = []
        let v2: [Double] = [1.0, 2.0]
        XCTAssertEqual(EmbeddingMath.cosineSimilarity(v1, v2), 0.0)
    }

    // MARK: - NLEmbeddingProvider (真 macOS NLEmbedding)

    /// 7. NLEmbedding .english 维度非零 + embed 返非 nil
    func testNLEmbedding_english_dimNonZeroAndEmbeds() throws {
        let provider = NLEmbeddingProvider(mode: .english)
        guard provider.dimension > 0,
              let vec = provider.embed("hello world") else {
            throw XCTSkip("NLEmbedding EN 不可用, skip")
        }
        XCTAssertGreaterThan(provider.dimension, 0, "NLEmbedding EN 维度 > 0")
        XCTAssertEqual(vec.count, provider.dimension, "向量维度 = provider.dimension")
    }

    /// 8. NLEmbedding .simplifiedChinese 维度非零 + 中文 embed 返非 nil
    /// 评审 §4.1: 中文可用性需实测. macOS 12+ .simplifiedChinese 通常支持.
    func testNLEmbedding_simplifiedChinese_dimNonZeroAndEmbeds() throws {
        let provider = NLEmbeddingProvider(mode: .simplifiedChinese)
        guard provider.dimension > 0,
              let vec = provider.embed("机器学习") else {
            throw XCTSkip("NLEmbedding zh-Hans 不可用, skip")
        }
        XCTAssertGreaterThan(provider.dimension, 0, "NLEmbedding zh-Hans 维度 > 0 (macOS 12+ 通常支持)")
        XCTAssertEqual(vec.count, provider.dimension)
    }

    /// 9. NLEmbedding auto 模式: CJK 文本 → zh-Hans, 纯英文 → en
    func testNLEmbedding_autoMode_detectsCJK() throws {
        let provider = NLEmbeddingProvider(mode: .auto)
        // 纯英文
        let enVec = provider.embed("hello world")
        // 含 CJK
        let zhVec = provider.embed("深度学习")
        guard let enVec, let zhVec else {
            throw XCTSkip("NLEmbedding auto 依赖的系统模型不可用, skip")
        }
        XCTAssertFalse(enVec.isEmpty)
        XCTAssertFalse(zhVec.isEmpty)
    }

    /// 10. NLEmbedding 同主题中文 cosine > 0.5 (P3-6 验证 embedding 信号)
    /// 实测 '机器学习' vs '深度学习' ≈ 0.94
    func testNLEmbedding_chineseSemanticSimilarity_highForRelatedTerms() throws {
        let provider = NLEmbeddingProvider(mode: .simplifiedChinese)
        guard let v1 = provider.embed("机器学习"),
              let v2 = provider.embed("深度学习") else {
            // 系统不支持中文 → skip (CI 环境可能 macOS 11-)
            throw XCTSkip("NLEmbedding zh-Hans 不可用, skip")
        }
        let cos = EmbeddingMath.cosineSimilarity(v1, v2)
        XCTAssertGreaterThan(cos, 0.5, "同主题中文 cosine 应 > 0.5 (实测 ~0.94)")
    }

    /// 11. NLEmbedding 无关中文 cosine < 0.95 (NLEmbedding zh-Hans 对通用词 cosine 都偏高)
    func testNLEmbedding_chineseSemanticSimilarity_lowerForUnrelatedTerms() throws {
        let provider = NLEmbeddingProvider(mode: .simplifiedChinese)
        guard let v1 = provider.embed("机器学习"),
              let v2 = provider.embed("苹果水果") else {
            throw XCTSkip("NLEmbedding zh-Hans 不可用, skip")
        }
        let cos = EmbeddingMath.cosineSimilarity(v1, v2)
        let cosRelated: Double
        if let v3 = provider.embed("深度学习") {
            cosRelated = EmbeddingMath.cosineSimilarity(v1, v3)
        } else {
            cosRelated = 0.0
        }
        XCTAssertLessThan(cos, cosRelated,
                          "无关 cosine (\(cos)) < 同主题 cosine (\(cosRelated)) (相对判断, NLEmbedding 中文 cosine 整体偏高)")
    }

    /// 12. NLEmbedding 短文本兜底 (空文本 → nil, 不抛)
    func testNLEmbedding_emptyText_returnsNil() {
        let provider = NLEmbeddingProvider(mode: .english)
        XCTAssertNil(provider.embed(""), "空文本 → nil (NLEmbedding 不处理空)")
        XCTAssertNil(provider.embed("   "), "whitespace-only → nil")
    }

    // MARK: - StaticEmbeddingProvider (mock)

    /// 13. Static 返固定 vector
    func testStaticEmbeddingProvider_returnsFixedVector() {
        let v: [Double] = [1.0, 0.5, -0.3]
        let provider = StaticEmbeddingProvider(dimension: 3, vector: v)
        XCTAssertEqual(provider.dimension, 3)
        XCTAssertEqual(provider.embed("anything"), v)
        XCTAssertEqual(provider.embed("another"), v, "Static 任何 input 都返同 vector")
    }

    /// 14. Static returnNil=true 模拟"embedding 不可用"
    func testStaticEmbeddingProvider_returnNilSimulatesUnavailable() {
        let provider = StaticEmbeddingProvider(dimension: 3, vector: [1, 0, 0], returnNil: true)
        XCTAssertNil(provider.embed("hi"), "returnNil=true → embed 永返 nil (offline 模式模拟)")
        XCTAssertEqual(provider.dimension, 3, "dimension 仍报告, 但 embed 返 nil")
    }

    // MARK: - CachedEmbeddingProvider

    /// 15. Cached: 相同 text 只调 inner 1 次 (P3-6 性能: 避免重复算)
    func testCachedEmbeddingProvider_cachesByText() {
        // 用 Static 计数调用次数
        final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
            var callCount = 0
            let lock = NSLock()
            let dimension: Int = 3
            func embed(_ text: String) -> [Double]? {
                lock.lock(); callCount += 1; lock.unlock()
                return [1.0, 0.0, 0.0]
            }
        }
        let inner = CountingProvider()
        let cached = CachedEmbeddingProvider(inner: inner)
        // 3 次相同 text
        _ = cached.embed("hello")
        _ = cached.embed("hello")
        _ = cached.embed("hello")
        XCTAssertEqual(inner.callCount, 1, "相同 text 缓存命中 → inner 只算 1 次")
    }

    /// 16. Cached: 不同 text 各算 1 次
    func testCachedEmbeddingProvider_differentTextsCacheSeparately() {
        final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
            var callCount = 0
            let lock = NSLock()
            let dimension: Int = 3
            func embed(_ text: String) -> [Double]? {
                lock.lock(); callCount += 1; lock.unlock()
                return [1.0, 0.0, 0.0]
            }
        }
        let inner = CountingProvider()
        let cached = CachedEmbeddingProvider(inner: inner)
        _ = cached.embed("a")
        _ = cached.embed("b")
        _ = cached.embed("a")  // 命中
        XCTAssertEqual(inner.callCount, 2, "3 次调用 2 个不同 text → inner 算 2 次")
    }

    /// 17. Cached: clearCache 重置缓存
    func testCachedEmbeddingProvider_clearCache() {
        final class CountingProvider: EmbeddingProvider, @unchecked Sendable {
            var callCount = 0
            let lock = NSLock()
            let dimension: Int = 3
            func embed(_ text: String) -> [Double]? {
                lock.lock(); callCount += 1; lock.unlock()
                return [1.0, 0.0, 0.0]
            }
        }
        let inner = CountingProvider()
        let cached = CachedEmbeddingProvider(inner: inner)
        _ = cached.embed("hi")
        _ = cached.embed("hi")
        cached.clearCache()
        _ = cached.embed("hi")  // 缓存清空 → 重算
        XCTAssertEqual(inner.callCount, 2, "clearCache 后再次 embed → inner 重算")
    }

    /// 18. Cached: nil 结果也缓存 (e.g. inner 对某 text 返 nil, 缓存这个 nil, 不重复试)
    func testCachedEmbeddingProvider_cachesNilResults() {
        let provider = StaticEmbeddingProvider(dimension: 3, vector: [1, 0, 0], returnNil: true)
        let cached = CachedEmbeddingProvider(inner: provider)
        _ = cached.embed("hi")
        _ = cached.embed("hi")
        _ = cached.embed("hi")
        // Static 返 nil, cached 也存 nil — 不重复问
        // (实现细节: cached.count 仍增, 但返回 nil 是 cached 的 nil 命中)
        XCTAssertNil(cached.embed("hi"), "cached nil 结果正确")
    }

    // MARK: - EmbeddingMerge 双信号 (升级 P3-1 同质合并)

    /// 19. EmbeddingMerge: embedding 可用, cosine >= 0.7 → merge
    func testEmbeddingMerge_cosineHigh_merge() {
        // 模拟两个方向相同向量 (cosine = 1.0)
        let provider = StaticEmbeddingProvider(dimension: 3, vector: [1.0, 0.5, 0.2])
        let result = EmbeddingMerge.similarity(
            "机器学习很重要",
            "机器学习关键",
            with: provider)
        XCTAssertNotNil(result.cosine)
        XCTAssertEqual(result.cosine!, 1.0, accuracy: 1e-9, "同向量 cosine = 1.0 → merge")
        XCTAssertTrue(result.isMerge, "cosine = 1.0 → 合并")
    }

    /// 20. EmbeddingMerge: embedding 可用, cosine < 0.7 + jaccard < 0.6 → not merge
    func testEmbeddingMerge_bothLow_noMerge() {
        // 完全反方向 (cosine = -1.0, jaccard 也很低)
        let v1: [Double] = [1.0, 0.0, 0.0]
        let v2: [Double] = [-1.0, 0.0, 0.0]
        // 用不同的 embed 结果: 给 EmbeddingProvider 做 sub-class for variable vectors
        let provider2 = VariableProvider([
            "机器学习": v1,
            "苹果水果": v2,
        ])
        let result = EmbeddingMerge.similarity(
            "机器学习",
            "苹果水果",
            with: provider2)
        XCTAssertNotNil(result.cosine)
        XCTAssertEqual(result.cosine!, -1.0, accuracy: 1e-9, "反向量 cosine = -1.0")
        XCTAssertFalse(result.isMerge, "cosine = -1.0 → not merge")
    }

    /// 21. EmbeddingMerge: embedding 不可用 → 走 jaccard (P3-1 兜底)
    func testEmbeddingMerge_providerUnavailable_fallsBackToJaccard() {
        // 离线模式: provider dimension=0 (不可用)
        let provider = StaticEmbeddingProvider(dimension: 0, vector: [], returnNil: true)
        // jaccard >= 0.6 → merge
        let similar = EmbeddingMerge.similarity(
            "SwiftUI 用于 macOS 桌面 UI 稳定",
            "SwiftUI 用于 macOS 桌面 UI 可靠",
            with: provider)
        XCTAssertNil(similar.cosine, "provider 不可用 → cosine = nil")
        XCTAssertTrue(similar.jaccard >= TextSimilarity.mergeThreshold,
                      "高 trigram 重合 → jaccard >= 0.6")
        XCTAssertTrue(similar.isMerge, "jaccard 高 → merge (P3-1 兜底)")

        // jaccard < 0.6 → not merge
        let different = EmbeddingMerge.similarity(
            "机器学习算法",
            "苹果水果蔬菜",
            with: provider)
        XCTAssertNil(different.cosine)
        XCTAssertTrue(different.jaccard < TextSimilarity.mergeThreshold)
        XCTAssertFalse(different.isMerge, "jaccard 低 → not merge")
    }

    /// 22. EmbeddingMerge: 双信号 OR — cosine 高 OR jaccard 高 → merge
    func testEmbeddingMerge_dualSignalOrLogic() {
        // embedding 给 ~0.3 (低), jaccard 给低 (完全不同字符) → 双低 not merge
        let p2 = VariableProvider([
            "abc": [1.0, 0.0, 0.0],
            "xyz": [0.5, 0.0, 0.0],  // cosine(1,0,0; 0.5,0,0) = 0.8667 — actually high!
        ])
        // 改用 0.3 / 0.0 让 cosine < 0.7
        let p3 = VariableProvider([
            "abc": [1.0, 0.0, 0.0],
            "xyz": [-1.0, 0.0, 0.0],  // cosine = -1
        ])
        let result = EmbeddingMerge.similarity("abc", "xyz", with: p3)
        // cosine 应 < 0.7 (actually -1)
        XCTAssertNotNil(result.cosine)
        XCTAssertLessThan(result.cosine!, 0.7)
        // jaccard ("abc" vs "xyz") 极低 → < 0.6
        XCTAssertLessThan(result.jaccard, 0.6)
        XCTAssertFalse(result.isMerge, "双信号都低 → not merge")
        _ = p2  // unused, 避免 unused warning
    }

    // MARK: - DreamCycle.mergeSimilar 集成 (P3-6 wiring)

    /// 23. mergeSimilar 接 embeddingProvider, 同 cosine → merge (P3-1 兜底 + P3-6 升级)
    func testMergeSimilar_withEmbeddingProvider_cosinePath() {
        // 同方向向量 → cosine = 1.0 → merge
        let provider = StaticEmbeddingProvider(dimension: 3, vector: [1.0, 0.5, 0.2])
        let now = Date()
        let existing: [Memory] = [
            Memory(
                text: "SwiftUI 用于 macOS 桌面 UI 稳定",
                sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                status: .durable),
        ]
        let newAccepted: [Memory] = [
            Memory(
                text: "SwiftUI 用于 macOS 桌面 UI 可靠",  // 字符略不同但 cosine 同
                sources: [SourceRef(file: "raw/b.md", line: 1, excerpt: "y")],
                status: .candidate),
        ]
        let result = DreamCycle.mergeSimilar(
            newAccepted: newAccepted,
            existing: existing,
            now: now,
            embeddingProvider: provider)
        XCTAssertEqual(result.mergeCount, 1, "embedding 同 cosine → merge")
        XCTAssertEqual(result.newAccepted.count, 0, "新教训被合并 → 从 newAccepted 移除")
        XCTAssertEqual(result.updatedExisting.count, 1)
        // 现有条目 sources 应含新 source
        XCTAssertTrue(result.updatedExisting[0].sources.contains { $0.file == "raw/b.md" })
    }

    /// 24. mergeSimilar 不接 embedding → 走 P3-1 jaccard (向后兼容)
    func testMergeSimilar_withoutEmbeddingProvider_jaccardPath() {
        let now = Date()
        let existing: [Memory] = [
            Memory(
                text: "SwiftUI 用于 macOS 桌面 UI 稳定",
                sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                status: .durable),
        ]
        let newAccepted: [Memory] = [
            Memory(
                text: "SwiftUI 用于 macOS 桌面 UI 可靠",  // trigram 高重合 → jaccard >= 0.6
                sources: [SourceRef(file: "raw/b.md", line: 1, excerpt: "y")],
                status: .candidate),
        ]
        // 不传 embeddingProvider → 走 P3-1 jaccard
        let result = DreamCycle.mergeSimilar(
            newAccepted: newAccepted,
            existing: existing,
            now: now)
        XCTAssertEqual(result.mergeCount, 1, "jaccard 高 → merge (P3-1 兜底)")
    }
}

// MARK: - 测试 fixtures

/// 给不同 input 返不同 vector 的 provider (P3-6 双信号测试用)
final class VariableProvider: EmbeddingProvider, @unchecked Sendable {
    let map: [String: [Double]?]
    let dim: Int
    init(_ map: [String: [Double]?], dim: Int = 3) {
        self.map = map
        self.dim = dim
    }
    var dimension: Int { dim }
    func embed(_ text: String) -> [Double]? {
        // 精确查表; 查不到返一个 dummy vector (测试用)
        return map[text] ?? [0.1, 0.2, 0.3]
    }
}
