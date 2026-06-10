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
    public init(durableMinSources: Int = 2, redactBeforeConsolidate: Bool = true) {
        self.durableMinSources = durableMinSources
        self.redactBeforeConsolidate = redactBeforeConsolidate
    }
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

    // MARK: - Three-Step CoT（nashsu/llm_wiki 借鉴思想，原生重写）
    //
    // 拆"读+写"为 analyze → generate → verify 三段，让 LLM 先**思考**（输出结构化草稿），
    // 再**生成**候选 Memory（带 source 引用），最后**校验**（沿用 verify 闸门）。
    //
    // 为什么不破坏现有 2 步入口？consolidate(_:) 仍保留，是 fast path / mock 测试用。
    // 真实生产 LLM 走 consolidate3Step。
    //
    // Step 1 (analyze): LLM 读 candidate 文本 + sources，输出"哪些实体、可能与谁
    //   矛盾、推荐结构"的结构化分析 JSON。LLM 不直接产 Memory，是思考阶段。
    // Step 2 (generate): 把 analyze JSON + 原 candidate 喂回 LLM，让它基于分析
    //   生成 0..N 个 Memory 草稿（带 source 引用）。LLM 现在写，不是想。
    // Step 3 (verify):  对每个生成的 Memory 走 verify() 闸门（与 2 步共享）。
    //
    // 期望效果：复杂场景下"读+写"一步时容易"边读边丢"的幻觉大幅减少；一步直接
    // 生成时编造 source 引用的概率也下降（因为先生成了分析，引用是按分析列的源文件
    // 再去原 candidate 里 grep/quote）。

    /// LLM 在 analyze 步输出的结构化分析（不直接是 Memory）
    /// 字段全 Optional 是为了容错：LLM 偶尔会缺字段（"reasoning" 是新加的），
    /// JSON 缺字段时 Codable 默认会抛错，但 Optional 不会。
    public struct Analysis: Codable, Equatable {
        public var keyEntities: [String]?
        public var keyConcepts: [String]?
        public var tensionsWithExisting: [String]?
        public var recommendedLessonTexts: [String]?
        public var reasoning: String?

        public init(keyEntities: [String]? = nil,
                    keyConcepts: [String]? = nil,
                    tensionsWithExisting: [String]? = nil,
                    recommendedLessonTexts: [String]? = nil,
                    reasoning: String? = nil) {
            self.keyEntities = keyEntities
            self.keyConcepts = keyConcepts
            self.tensionsWithExisting = tensionsWithExisting
            self.recommendedLessonTexts = recommendedLessonTexts
            self.reasoning = reasoning
        }

        // 容错访问：nil 给空集合
        public var entitiesSafe: [String] { keyEntities ?? [] }
        public var conceptsSafe: [String] { keyConcepts ?? [] }
        public var tensionsSafe: [String] { tensionsWithExisting ?? [] }
        public var lessonsSafe: [String] { recommendedLessonTexts ?? [] }
        public var reasoningSafe: String { reasoning ?? "" }
    }

    /// generate 步 LLM 输出的"候选 Memory 草稿"（已带 source 引用 + decayClass 建议）
    /// 同样字段全 Optional 以容错
    public struct MemoryDraft: Codable, Equatable {
        public var text: String?
        public var sourceFile: String?
        public var sourceLine: Int?
        public var sourceExcerpt: String?
        public var decayClassRaw: String?

        public init(text: String? = nil, sourceFile: String? = nil,
                    sourceLine: Int? = nil, sourceExcerpt: String? = nil,
                    decayClassRaw: String? = nil) {
            self.text = text
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
            self.sourceExcerpt = sourceExcerpt
            self.decayClassRaw = decayClassRaw
        }

        public var textSafe: String { text ?? "" }
        public var sourceFileSafe: String { sourceFile ?? "" }
        public var sourceLineSafe: Int { sourceLine ?? 0 }
        public var sourceExcerptSafe: String { sourceExcerpt ?? "" }
    }

    public enum Consolidate3StepError: Error, CustomStringConvertible {
        case analysisParseFailed(String)
        case draftsParseFailed(String)
        public var description: String {
            switch self {
            case .analysisParseFailed(let s): return "analyze 步 JSON 解析失败: \(s)"
            case .draftsParseFailed(let s):  return "generate 步 JSON 解析失败: \(s)"
            }
        }
    }

    /// Step 1: analyze —— LLM 读 candidate（已脱敏），输出结构化分析
    public func analyze(_ candidate: Memory) async throws -> Analysis {
        let evidence = candidate.sources
            .map { "[\($0.file):\($0.line)] \($0.excerpt)" }
            .joined(separator: "\n")
        let system = """
        你是严格的分析师。先**思考**再回答。
        你的输出必须是合法 JSON（无 markdown 包裹），格式：
        {"keyEntities":[...], "keyConcepts":[...], "tensionsWithExisting":[...],
         "recommendedLessonTexts":[...], "reasoning":"..."}
        - keyEntities: 文中提到的关键实体（人/项目/工具/概念名）
        - keyConcepts: 抽象概念或模式
        - tensionsWithExisting: 与已知知识可能的矛盾点（无则空数组）
        - recommendedLessonTexts: 推荐提炼出的教训文本（每条 1 句，不超 80 字）
        - reasoning: 你的推理过程（让人能审查）
        """
        let user = """
        候选观察文本：
        \(candidate.text)

        来源片段：
        \(evidence)

        请按 JSON 格式输出你的分析。
        """
        let raw = try await llm.complete(system: system, user: user)
        return try Self.parseAnalysis(raw)
    }

    /// Step 2: generate —— LLM 读 analyze 输出 + 候选原文本，产出 0..N 个 MemoryDraft
    public func generate(candidate: Memory, analysis: Analysis) async throws -> [MemoryDraft] {
        let evidence = candidate.sources
            .map { "[\($0.file):\($0.line)] \($0.excerpt)" }
            .joined(separator: "\n")
        let analysisJSON = (try? JSONEncoder().encode(analysis)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        let system = """
        你是严格的提炼员。**只能**基于下面"分析"和"来源片段"提炼教训。
        你的输出必须是合法 JSON 数组（无 markdown 包裹），每个元素：
        {"text":"...", "sourceFile":"raw/xxx.md", "sourceLine":N, "sourceExcerpt":"...",
         "decayClassRaw":"slow|normal|fast"}
        - text: 1 句话教训，≤80 字
        - sourceFile/sourceLine/sourceExcerpt: 必须从下面"来源片段"里选一个真实存在
          的引用，**禁止编造**
        - decayClassRaw: slow=架构/长期决策、normal=通用教训、fast=临时观察/bug
        - 没东西可提炼就输出空数组 []
        """
        let user = """
        分析（已由分析员产出）：
        \(analysisJSON)

        原候选文本：
        \(candidate.text)

        来源片段（仅可引用这些）：
        \(evidence)

        请输出 JSON 数组。
        """
        let raw = try await llm.complete(system: system, user: user)
        return try Self.parseDrafts(raw)
    }

    /// Three-Step 完整流水线：对每个 raw 候选走 3 步，最后返回通过 verify 的 Memory 列表
    public func consolidate3Step(
        _ raw: [Memory],
        consolidate2StepFallback: Bool = true
    ) async throws -> [Memory] {
        var out: [Memory] = []
        for var m in raw {
            if config.redactBeforeConsolidate { m = redactor.redact(m) }
            guard hasSource(m) else { continue }
            do {
                let analysis = try await analyze(m)
                let drafts = try await generate(candidate: m, analysis: analysis)
                for d in drafts {
                    let text = d.textSafe
                    guard !text.isEmpty else { continue }
                    let draftSource = SourceRef(file: d.sourceFileSafe,
                                                line: d.sourceLineSafe,
                                                excerpt: d.sourceExcerptSafe)
                    // 来源真实性闸：sourceFile 必须与原 candidate 的 source 同文件
                    guard m.sources.contains(where: { $0.file == d.sourceFileSafe })
                    else { continue }
                    let draft = Memory(
                        text: text,
                        sources: [draftSource],
                        decayClass: DecayClass(rawValue: d.decayClassRaw ?? "") ?? .normal
                    )
                    guard try await verify(draft) else { continue }
                    var accepted = draft
                    accepted.status = classify(accepted)
                    out.append(accepted)
                }
            } catch {
                if consolidate2StepFallback {
                    // 三段任一失败：回退到两段（旧行为）
                    let fallback = try await consolidate([m])
                    out.append(contentsOf: fallback)
                } else {
                    // fallback 关：重新抛出，调用方需要知道三段任一阶段崩了
                    throw error
                }
            }
        }
        return out
    }

    // MARK: - JSON 解析小工具（容错：LLM 偶尔会裹 markdown ```json``` 块）

    static func parseAnalysis(_ raw: String) throws -> Analysis {
        let cleaned = stripMarkdownFence(raw)
        guard let data = cleaned.data(using: .utf8),
              let a = try? JSONDecoder().decode(Analysis.self, from: data) else {
            throw Consolidate3StepError.analysisParseFailed(cleaned.prefix(200).description)
        }
        return a
    }

    static func parseDrafts(_ raw: String) throws -> [MemoryDraft] {
        let cleaned = stripMarkdownFence(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw Consolidate3StepError.draftsParseFailed(cleaned.prefix(200).description)
        }
        // 容错：可能返回对象或数组。对象里包 drafts 字段也接受
        if let arr = try? JSONDecoder().decode([MemoryDraft].self, from: data) {
            return arr
        }
        if let obj = try? JSONDecoder().decode(DraftEnvelope.self, from: data) {
            return obj.drafts ?? []
        }
        throw Consolidate3StepError.draftsParseFailed(cleaned.prefix(200).description)
    }

    private struct DraftEnvelope: Codable {
        var drafts: [MemoryDraft]?
    }

    /// 剥掉 LLM 偶发包的 ```json ... ``` 围栏
    static func stripMarkdownFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // 去掉首行 ``` 或 ```json
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            } else {
                t = String(t.dropFirst(3))
            }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
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
