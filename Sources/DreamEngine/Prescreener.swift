import Foundation

/// P0-1 矛盾检测预筛 (0 成本 LLM 漏斗)
///
/// 两级漏斗:
///   1. 零成本预筛 — 共享 KnowledgeGraph 邻居 OR 共享文本实体 token → 候选 pair
///   2. LLM 比对 (原有 conflicts()) — 只对预筛出的 ≤ maxPairsPerNight 对跑
///
/// 设计要点:
/// - 第一级**绝不调 LLM** (这是核心降本). 仅字符串集合交集 + Adamic-Adar.
/// - 实体 token: 中文按字符 (单字粒度, 因为没分词器), 英文按 \w+; 长度 ≥2; 小写化; 简单停用词表去 "的/了/the/a" 等.
/// - Adamic-Adar 阈值: 0 (有共同邻居就算相关, 因为同一主题容易有共同源文件邻居)
/// - maxPairsPerNight: 50 (spec). 超出部分写到 dream-report "未比对完" 段.
/// - 旧 API 兼容: 保留原 `link(candidates:against:)` 但内部用预筛路径.
public struct Prescreener {
    public struct Result {
        /// 预筛留下的 pair, 准备调 LLM
        public let toCompare: [(candidate: Memory, existing: Memory)]
        /// 预筛淘汰的 pair (UI 可选展示 "已跳过 N 对")
        public let skipped: Int
        /// 预筛留下但被 maxPairsPerNight 截断的 pair
        public let truncated: Int
        /// 预筛留下总数 (toCompare.count + truncated)
        public let totalKeptByScreener: Int
    }

    public let maxPairsPerNight: Int
    public let graph: KnowledgeGraph

    public init(maxPairsPerNight: Int = 50, graph: KnowledgeGraph) {
        self.maxPairsPerNight = maxPairsPerNight
        self.graph = graph
    }

    /// 预筛: 对每个 candidate, 找出与哪些 existing 值得走 LLM.
    /// - candidates: 本轮新教训
    /// - existings: 现有 durable 记忆
    public func prescreen(candidates: [Memory], against existings: [Memory]) -> Result {
        // 预算: 全局一对 N*cap 平衡. spec 说"durable=500 + 新=10 ≤ 50"
        // 实际算法: 给每对打分 (0 = 无关, >0 = 相关), 取全局 top maxPairsPerNight
        var scored: [(score: Double, cand: Memory, exist: Memory)] = []
        scored.reserveCapacity(candidates.count * existings.count / 4)

        for cand in candidates {
            let candTokens = TextEntityTokens.extract(cand.text)
            let candNeighbors = graph.neighbors(of: cand.id)
            for exist in existings {
                if exist.id == cand.id { continue }
                let existTokens = TextEntityTokens.extract(exist.text)
                // 0 成本判定 1: 共享至少 1 个实体 token
                let tokenOverlap = !candTokens.isDisjoint(with: existTokens)
                // 0 成本判定 2: 图邻接 (Adamic-Adar)
                let aa = graph.adamicAdar(cand.id, exist.id)
                let keep = tokenOverlap || aa > 0
                if keep {
                    // 评分: 优先 token 重合 (语义强), 叠加图分
                    let score = (tokenOverlap ? 1.0 : 0.0) + aa
                    scored.append((score, cand, exist))
                }
            }
        }

        // 全局排序 + 截断
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.cand.id < rhs.cand.id }
            return lhs.score > rhs.score
        }
        let totalKept = scored.count
        let toCompareCount = min(totalKept, maxPairsPerNight)
        let truncated = totalKept - toCompareCount

        let toCompare = scored.prefix(toCompareCount).map { ($0.cand, $0.exist) }
        let skipped = max(0, (candidates.count * existings.count) - totalKept)

        return Result(
            toCompare: Array(toCompare),
            skipped: skipped,
            truncated: truncated,
            totalKeptByScreener: totalKept
        )
    }
}

/// 极简实体 token 提取. 不引 NLP 库.
/// - 英文: \w+ 长度 ≥ 2
/// - 中文: 单字粒度 (无分词器, 保守起见) 长度 ≥ 1, 过滤常见停用词
/// - 数字: 长度 ≥ 2 (避免把 "1" 跟 "12" 当同一个)
/// - 全部小写
/// - 去重返回 Set
public enum TextEntityTokens {
    private static let stopwords: Set<String> = [
        // 中文高频停用字
        "的", "了", "在", "是", "我", "有", "和", "就", "不", "人", "都", "一", "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "没", "看", "好", "自", "之", "与", "或", "其", "可", "能", "本", "而", "且", "但", "如", "此", "因", "所", "为", "以", "对", "等",
        "用", "把", "被", "从", "向", "给", "到", "于", "跟", "和", "跟", "比", "等", "等等",
        // 英文停用词
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could", "should",
        "to", "of", "in", "for", "on", "with", "at", "by", "from", "as", "into",
        "and", "or", "not", "no", "yes", "this", "that", "these", "those",
        "it", "its", "they", "them", "their", "we", "our", "you", "your", "i", "my", "me",
    ]

    public static func extract(_ text: String) -> Set<String> {
        var out: Set<String> = []
        // 1. 英文 / 数字 / 含字母混合: \w+ 长度 ≥ 2
        let enPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9_]{2,}"#)
        if let regex = enPattern {
            let range = NSRange(text.startIndex..., in: text)
            for m in regex.matches(in: text, range: range) {
                if let r = Range(m.range, in: text) {
                    let token = text[r].lowercased()
                    if !stopwords.contains(token) {
                        out.insert(token)
                    }
                }
            }
        }
        // 2. 中文单字: 长度 ≥ 1 + 过滤停用字
        for ch in text {
            // CJK Unified Ideographs 基本平面 U+4E00..U+9FFF
            if let scalar = ch.unicodeScalars.first(where: { $0.isASCII == false }),
               scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                let s = String(ch)
                if !stopwords.contains(s) {
                    out.insert(s)
                }
            }
        }
        return out
    }
}
