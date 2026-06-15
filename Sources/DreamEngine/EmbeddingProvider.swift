import Foundation
import NaturalLanguage

/// P3-6 评审 §4.1 修复: 本地 embedding (NLEmbedding 系统自带, 离线, 免费).
/// 一份记忆文本向量可同时解决三个独立提出的需求:
/// 1. 同质合并 (§1.1 修复核心): 新教训 vs ledger 余弦相似 > 阈值 → 合并 source
/// 2. 矛盾预筛 (P0-1): 只对相似度中高的记忆对调 LLM 判矛盾, O(N×M) → O(top-k)
/// 3. 图谱语义边 (P2-2): 补上跨文件同主题连边, 解决 2.2 的信号稀薄
///
/// P3-6 实现:
/// - `EmbeddingProvider` 协议: `embed(_ text: String) -> [Double]?` (nil = LLM 拒绝/不支持该语言)
/// - `NLEmbeddingProvider` 实现: 走 NaturalLanguage 框架. 中文用 .simplifiedChinese, 英文用 .english, 混合优先 .simplifiedChinese
/// - `StaticEmbeddingProvider` mock: 测试用
/// - `CachedEmbeddingProvider` 包装: in-memory 缓存 (避免重复算)
/// - `cosineSimilarity(_:_:)` helper
/// - `EmbeddingAvailability` 检测: NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) 在 macOS 12+ 可用, 否则 nil
public protocol EmbeddingProvider: Sendable {
    /// 文本 → 向量. nil = LLM/embedding 不可用 (offline 模式 / 不支持该语言).
    func embed(_ text: String) -> [Double]?
    /// 向量维度 (预计算). 0 = 不可用.
    var dimension: Int { get }
}

// MARK: - Cosine similarity (共用 helper)

public enum EmbeddingMath {
    /// 向量余弦相似度. 返 [-1.0, 1.0]. 0.0 = 正交无相关, 1.0 = 同向, -1.0 = 反向.
    /// 处理零向量 (返 0.0, 避免 NaN).
    public static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot = 0.0, n1 = 0.0, n2 = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            n1 += a[i] * a[i]
            n2 += b[i] * b[i]
        }
        let denom = (n1 * n2).squareRoot()
        guard denom > 0 else { return 0.0 }  // 零向量 → 0 (避免除零)
        return dot / denom
    }
}

// MARK: - NLEmbeddingProvider (NaturalLanguage 框架)

/// macOS 12+ 用 NLEmbedding. 自动选语言: 含 CJK 字符优先 .simplifiedChinese, 否则 .english.
/// macOS 11- 不支持 sentenceEmbedding (回退 nil).
public struct NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case simplifiedChinese
        case english
        case auto  // 自动判 (默认)
    }

    public let mode: Mode
    public let dimension: Int

    public init(mode: Mode = .auto) {
        self.mode = mode
        // 探测维度 (取一语言 embedding 的 dim 即可, EN/ZH 同框架)
        let probeLang: NLLanguage = (mode == .english) ? .english : .simplifiedChinese
        if let probe = NLEmbedding.sentenceEmbedding(for: probeLang) {
            self.dimension = probe.dimension
        } else {
            self.dimension = 0
        }
    }

    public func embed(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lang: NLLanguage
        switch mode {
        case .simplifiedChinese: lang = .simplifiedChinese
        case .english: lang = .english
        case .auto: lang = Self.detectLanguage(trimmed)
        }
        guard let emb = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        return emb.vector(for: trimmed)
    }

    /// 自动判语言: 含 CJK 字符 → .simplifiedChinese, 否则 .english
    static func detectLanguage(_ text: String) -> NLLanguage {
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {  // CJK
                return .simplifiedChinese
            }
        }
        return .english
    }
}

// MARK: - CachedEmbeddingProvider (in-memory 缓存)

/// 包装任何 EmbeddingProvider, in-memory 缓存 (key = text hash). 避免重复算向量.
/// **重要**: 缓存按 [String: [Double]?] 存, 大小受 N (调用方管理的 memory 数) 影响.
/// 生产: 几百条 memory × 几百字符 = KB 级, 内存可忽略.
public final class CachedEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let inner: EmbeddingProvider
    private var cache: [String: [Double]?] = [:]
    // P1-1 修复 (v0.14, 2026-06-15): NSLock 改 os_unfair_lock. 性能更好 (Apple
    // 推荐, Foundation 自 iOS 10 / macOS 10.12 走), Swift 6 strict-concurrency
    // 不警告. 注意: os_unfair_lock 是值类型, 必须用 ManagedBuffer / 类属性
    // 才能保证 lock state 不被 copy. 这里用 class 自身做 owner.
    private var lock = os_unfair_lock_s()

    public var dimension: Int { inner.dimension }

    public init(inner: EmbeddingProvider) {
        self.inner = inner
    }

    public func embed(_ text: String) -> [Double]? {
        let key = text
        os_unfair_lock_lock(&lock)
        if let cached = cache[key] {
            os_unfair_lock_unlock(&lock)
            return cached
        }
        os_unfair_lock_unlock(&lock)
        // cache miss: 调 inner, 存结果
        let result = inner.embed(text)
        os_unfair_lock_lock(&lock)
        cache[key] = result
        os_unfair_lock_unlock(&lock)
        return result
    }

    /// 清空缓存 (e.g. test 间重置)
    public func clearCache() {
        os_unfair_lock_lock(&lock)
        cache.removeAll()
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - StaticEmbeddingProvider (测试用)

/// 静态 mock: 返固定 vector. 测试 EmbeddingSemanticEdge / 高层逻辑不依赖真实 NLEmbedding.
public struct StaticEmbeddingProvider: EmbeddingProvider, Sendable {
    public let dimension: Int
    public let vector: [Double]
    /// nil = 模拟"embedding 不可用" (offline 模式)
    public let returnNil: Bool

    public init(dimension: Int, vector: [Double], returnNil: Bool = false) {
        self.dimension = dimension
        self.vector = vector
        self.returnNil = returnNil
    }

    public func embed(_ text: String) -> [Double]? {
        returnNil ? nil : vector
    }
}

// MARK: - P3-6 同质合并 (替代/补充 TextSimilarity.trigram Jaccard)

/// P3-6 评审 §1.1 升级: embedding 相似度作"同质合并"主信号, 字符 trigram Jaccard 兜底.
/// 设计:
/// - embedding 可用 + 2 边都 embed 成功 → 用 cosine
/// - 否则 (embedding 不可用 / 某边 embed 失败) → 走 trigram Jaccard (P3-1 既有, 向后兼容)
public enum EmbeddingMerge {
    /// P3-6 阈值: cosine >= 0.85 视为同质. NLEmbedding 实测:
    /// - '机器学习' vs '深度学习' = 0.94 (同主题)
    /// - '机器学习' vs '苹果水果' = 0.81 (无关但 NLEmbedding 整体偏高)
    /// 阈值 0.85 平衡: 大于 0.85 才是同主题. P3-1 字符 Jaccard 阈值 0.6 仍兜底 (双信号 OR).
    public static let cosineMergeThreshold: Double = 0.85

    /// 同质合并判定. embedding 可用 → cosine. 否则 → Jaccard (P3-1 兜底).
    /// - 返 (cosine, jaccard) 元组 (P3-1 加 P3-6 信号, 调试用)
    public static func similarity(_ a: String, _ b: String, with provider: EmbeddingProvider?)
    -> (cosine: Double?, jaccard: Double, isMerge: Bool) {
        let jaccard = TextSimilarity.jaccard(a, b)
        // P3-1 兜底: jaccard >= 0.6 视为同质
        let mergeByJaccard = jaccard >= TextSimilarity.mergeThreshold
        guard let provider = provider, provider.dimension > 0,
              let v1 = provider.embed(a),
              let v2 = provider.embed(b) else {
            // embedding 不可用 → 走 P3-1 Jaccard (jaccard 已算)
            return (nil, jaccard, mergeByJaccard)
        }
        let cos = EmbeddingMath.cosineSimilarity(v1, v2)
        // P3-6: cosine >= 0.7 OR jaccard >= 0.6 → merge
        // (双信号 OR — 任一信号判 merge, 防 embedding 极端情况漏检)
        let mergeByCos = cos >= cosineMergeThreshold
        return (cos, jaccard, mergeByCos || mergeByJaccard)
    }
}
