import Foundation

/// 矛盾检测：新教训写入前，与现有 durable 教训比对。
/// 参考 agentmemory 的"写时矛盾检测与消解"思想。
///
/// 关键决策：检测到矛盾**不自动删除**任何一方，而是双向建立 contradicts 链接，
/// 让 Decayer 把它们标为 needsReview，交人工在 DreamPanel 裁决。
/// 这与内核的"保守优先、绝不自动删"原则一致。
public struct ContradictionDetector {
    public let llm: LLMProvider

    public init(llm: LLMProvider) { self.llm = llm }

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
    /// 返回更新后的 (新教训, 受影响的现有记忆)。两边都返回，便于上层写回 ledger。
    public func link(candidates: [Memory],
                     against existing: [Memory]) async throws -> (candidates: [Memory], existing: [Memory]) {
        var cand = candidates
        var exist = existing
        // 只与 durable 比对：candidate 之间尚未确立，比对意义不大且放大成本
        let durableIdx = exist.indices.filter { exist[$0].status == .durable }

        for i in cand.indices {
            for j in durableIdx {
                if try await conflicts(cand[i], exist[j]) {
                    if !cand[i].contradicts.contains(exist[j].id) {
                        cand[i].contradicts.append(exist[j].id)
                    }
                    if !exist[j].contradicts.contains(cand[i].id) {
                        exist[j].contradicts.append(cand[i].id)
                    }
                }
            }
        }
        return (cand, exist)
    }
}
