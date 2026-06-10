import Foundation

// MARK: - 可切换的 LLM 接口（本地 Ollama / 云 API 都实现它）

public protocol LLMProvider {
    /// 给定 prompt 返回文本。实现方负责本地或云的差异。
    func complete(system: String, user: String) async throws -> String
}

// MARK: - 整合器：从 raw 候选提炼教训，三道防幻觉闸门（架构文档第 5 节）

public struct ConsolidationConfig {
    /// 升为 durable（进 MEMORY.md）所需的最少独立来源数
    public var durableMinSources: Int = 2
    /// 是否在提炼前对教训文本与来源片段脱敏
    public var redactBeforeConsolidate: Bool = true
    public init() {}
}

public struct Consolidator {
    public let llm: LLMProvider
    public let config: ConsolidationConfig
    public let redactor: Redactor

    public init(llm: LLMProvider,
                config: ConsolidationConfig = ConsolidationConfig(),
                redactor: Redactor = Redactor()) {
        self.llm = llm; self.config = config; self.redactor = redactor
    }

    /// 闸门 1：丢弃无来源引用的教训
    func hasSource(_ m: Memory) -> Bool { !m.sources.isEmpty }

    /// 闸门 2：根据独立来源数决定状态
    func classify(_ m: Memory) -> MemoryStatus {
        m.distinctSourceCount >= config.durableMinSources ? .durable : .candidate
    }

    /// 闸门 3：回读校验——把教训 + 其引用片段回喂 LLM，问是否被支撑
    public func verify(_ m: Memory) async throws -> Bool {
        let evidence = m.sources
            .map { "[\($0.file):\($0.line)] \($0.excerpt)" }
            .joined(separator: "\n")
        let system = """
        你是严格的事实校验器。只依据提供的证据片段判断结论是否成立。
        证据未明确支撑就回答 NO。只输出 YES 或 NO。
        """
        let user = """
        结论：\(m.text)
        证据片段：
        \(evidence)

        这些证据是否支撑该结论？
        """
        let answer = try await llm.complete(system: system, user: user)
        return answer.uppercased().contains("YES")
    }

    /// 完整流水线：原始候选教训 → 经四闸过滤后的可信教训
    /// 闸门 0（脱敏）→ 1（有来源）→ 3（回读校验）→ 2（分级）
    public func consolidate(_ raw: [Memory]) async throws -> [Memory] {
        var out: [Memory] = []
        for var m in raw {
            if config.redactBeforeConsolidate { m = redactor.redact(m) }  // 闸门 0
            guard hasSource(m) else { continue }            // 闸门 1
            guard try await verify(m) else { continue }     // 闸门 3
            m.status = classify(m)                           // 闸门 2
            out.append(m)
        }
        return out
    }

    /// 带矛盾检测的完整流水线：先 consolidate，再与现有 durable 记忆比对建链。
    /// 返回 (通过的新教训, 被链接更新的现有记忆)。矛盾两方都不删，交人工裁决。
    public func consolidateAndLink(
        _ raw: [Memory],
        against existing: [Memory]
    ) async throws -> (accepted: [Memory], updatedExisting: [Memory]) {
        let accepted = try await consolidate(raw)
        let detector = ContradictionDetector(llm: llm)
        let linked = try await detector.link(candidates: accepted, against: existing)
        return (linked.candidates, linked.existing)
    }
}
