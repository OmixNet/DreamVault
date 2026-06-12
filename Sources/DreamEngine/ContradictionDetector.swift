import Foundation

/// 矛盾检测：新教训写入前，与现有 durable 教训比对。
/// 参考 agentmemory 的"写时矛盾检测与消解"思想。
///
/// 关键决策：检测到矛盾**不自动删除**任何一方，而是双向建立 contradicts 链接，
/// 让 Decayer 把它们标为 needsReview，交人工在 DreamPanel 裁决。
/// 这与内核的"保守优先、绝不自动删"原则一致。
///
/// P0-1 改动 (成本债): 之前是 O(candidates × durable) LLM 调用，durable=500 + 新=10 = 5000 次。
/// 改两级漏斗: Prescreener 零成本过滤（共享 token / Adamic-Adar） → 只对留下的对调 LLM。
/// 预算硬上限: maxPairsPerNight=50 (默认), 超出截断 + report 写 "未比对完，明晚继续"。
public struct ContradictionDetector {
    public let llm: LLMProvider
    public let prescreener: Prescreener
    /// 最近一次 link() 的预筛统计 — 让 DreamCycle 写进 dream-report 末尾的 "## Prescreen" 段
    public private(set) var lastPrescreenResult: Prescreener.Result? = nil
    public private(set) var lastLLMCalls: Int = 0

    public init(llm: LLMProvider,
                maxPairsPerNight: Int = 50,
                graph: KnowledgeGraph = KnowledgeGraph()) {
        self.llm = llm
        self.prescreener = Prescreener(maxPairsPerNight: maxPairsPerNight, graph: graph)
    }

    /// 暴露 mutable 接口给 DreamCycle 写统计 (替代 lastPrescreenResult 字段)
    public mutating func recordStats(prescreen: Prescreener.Result, llmCalls: Int) {
        self.lastPrescreenResult = prescreen
        self.lastLLMCalls = llmCalls
    }

    /// 询问 LLM：candidate 是否与 existing 矛盾。返回 true=矛盾。
    /// 用窄问题 + 强制单词输出，降低误判与幻觉。
    func conflicts(_ candidate: Memory, _ existing: Memory) async throws -> Bool {
        let system = """
        你判断两条知识是否互相矛盾（不能同时为真）。
        仅当它们就同一主题给出不可调和的结论时才算矛盾。
        主题不同、或只是侧重不同、或可同时成立，都不算矛盾。
        只输出 CONFLICT 或 OK。
        """
        let user = """
        知识 A：\(candidate.text)
        知识 B：\(existing.text)

        A 与 B 是否矛盾？
        """
        let answer = try await llm.complete(system: system, user: user)
        return answer.uppercased().contains("CONFLICT")
    }

    /// 把一批新教训与现有 durable 记忆比对，就地写入双向 contradicts 链接。
    /// P0-1 改造: 先 Prescreener 过滤 (0 LLM), 只对 ≤ maxPairsPerNight 对跑 LLM.
    public mutating func link(candidates: [Memory],
                              against existing: [Memory]) async throws -> (candidates: [Memory], existing: [Memory]) {
        var cand = candidates
        var exist = existing
        // 只与 durable 比对：candidate 之间尚未确立，比对意义不大且放大成本
        let durableArr = exist.filter { $0.status == .durable }

        // 1. 预筛
        let prescreenResult = prescreener.prescreen(candidates: cand, against: durableArr)
        self.lastPrescreenResult = prescreenResult
        self.lastLLMCalls = 0

        // 2. 只对预筛留下的对调 LLM
        for pair in prescreenResult.toCompare {
            self.lastLLMCalls += 1
            if try await conflicts(pair.candidate, pair.existing) {
                if let i = cand.firstIndex(where: { $0.id == pair.candidate.id }) {
                    if !cand[i].contradicts.contains(pair.existing.id) {
                        cand[i].contradicts.append(pair.existing.id)
                    }
                }
                if let j = exist.firstIndex(where: { $0.id == pair.existing.id }) {
                    if !exist[j].contradicts.contains(pair.candidate.id) {
                        exist[j].contradicts.append(pair.candidate.id)
                    }
                }
            }
        }
        return (cand, exist)
    }
}
