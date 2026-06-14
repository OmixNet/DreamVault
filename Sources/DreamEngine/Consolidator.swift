import Foundation

// MARK: - 可切换的 LLM 接口（本地 Ollama / 云 API 都实现它）

public protocol LLMProvider: Sendable {
    /// 给定 prompt 返回文本。实现方负责本地或云的差异。
    func complete(system: String, user: String) async throws -> String
}

// MARK: - 整合器：从 raw 候选提炼教训，三道防幻觉闸门（架构文档第 5 节）

public struct ConsolidationConfig: Sendable {
    /// 升为 durable（进 MEMORY.md）所需的最少独立来源数
    public var durableMinSources: Int = 2
    /// 是否在提炼前对教训文本与来源片段脱敏
    public var redactBeforeConsolidate: Bool = true
    /// 走三段式 CoT（analyze → generate → verify），生产 LLM 推荐 true；
    /// false 则走最便宜的 2 步快速路径（mock / 极快模型）。
    /// 三段 CoT 默认开 (P3-3 评审 §1.2 修复). 老默认 false 把原文当教训污染 ledger.
    /// 真实 LLM provider (Ollama / OpenAI-compat) 走 3 段防幻觉 (analyze + generate + verify + SourceRefValidator).
    /// mock provider 走 2 步快速路径 (test/debug 用).
    public var useThreeStepCoT: Bool = true
    /// P3-3 评审 §1.2 修复: 3 段失败时**不**回退到 2 步 (那把全文当教训污染 ledger).
    /// 默认 false: 3 段失败 → 跳过该 candidate, 留明晚重试.
    /// fallback=true: 仍走 2 步 (但仅 mock provider 安全, 真实 provider 建议 false).
    public var fallbackOnThreeStepFailure: Bool = false
    /// 跨候选并发上限。LLM 是 IO-bound（本地 Ollama 4+ 容易 OOM/超时）。
    /// P3-T2: 默认 2（Ollama 7B 量化安全线），上限 4（防止用户填 100）。
    /// 0 或 1 = 串行。Settings 让用户调。
    public var concurrency: Int = 2

    public init() {}
    public init(
        durableMinSources: Int = 2,
        redactBeforeConsolidate: Bool = true,
        useThreeStepCoT: Bool = true,
        fallbackOnThreeStepFailure: Bool = false,
        concurrency: Int = 2
    ) {
        self.durableMinSources = durableMinSources
        self.redactBeforeConsolidate = redactBeforeConsolidate
        self.useThreeStepCoT = useThreeStepCoT
        self.fallbackOnThreeStepFailure = fallbackOnThreeStepFailure
        // P3-T2: init 阶段就 cap，避免下游调用忘了再 max/min
        self.concurrency = max(1, min(4, concurrency))
    }
}

public struct Consolidator: Sendable {
    public let llm: LLMProvider
    public let config: ConsolidationConfig
    public let redactor: Redactor
    /// P0-3: 源文件内容 (relPath -> 脱敏后 body), 供 SourceRefValidator 闸门校验 draft.excerpt
    /// 是不是真在源文件里. nil = 旧调用方, 闸门降级为 "全通过" (向后兼容).
    public let sourceContents: [String: String]

    public init(llm: LLMProvider,
                config: ConsolidationConfig = .init(),
                redactor: Redactor = Redactor(),
                sourceContents: [String: String] = [:]) {
        self.llm = llm
        self.config = config
        self.redactor = redactor
        self.sourceContents = sourceContents
    }

    /// P0-3: 跑闸门. 返回 (通过?, 拒收数).
    /// - 通过: true
    /// - 拒收: false (调用方把拒收数累加到 rejectedFabricatedCount)
    /// 设计: 不 mutating self, 让并发 TaskGroup 路径也能用
    func checkSourceRefGate(draftExcerpt: String, draftFile: String) -> (passed: Bool, rejectedCount: Int) {
        let lookup = sourceContents
        let (passed, rejected) = SourceRefValidator.validateBatch(
            refs: [(relPath: draftFile, excerpt: draftExcerpt)],
            fileContentLookup: lookup
        )
        if !rejected.isEmpty {
            FileHandle.standardError.write(Data(
                "[P0-3] fabricated excerpt rejected: file=\(draftFile) excerpt=\"\(draftExcerpt.prefix(80))\" rejected=\(rejected)\n".utf8))
            return (false, rejected.count)
        }
        _ = passed
        return (true, 0)
    }

    // MARK: - P3-T2: LLM 重试 + 指数退避
    /// 把 llm.complete 包成最多 3 次重试（1s → 2s → 4s + 0-500ms jitter）。
    /// 失败原因通常是网络波动 / 本地模型偶发吐乱码。重试都写到 stderr，
    /// dream-report 不记重试细节（用户只看 "FAIL: ..." 终态）。
    func callLLMWithRetry(system: String, user: String,
                          maxAttempts: Int = 3) async throws -> String {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let out = try await llm.complete(system: system, user: user)
                if attempt > 1 {
                    FileHandle.standardError.write(Data(
                        "[Consolidator] LLM 重试成功 (attempt \(attempt)/\(maxAttempts))\n".utf8))
                }
                return out
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let baseDelay = pow(2.0, Double(attempt - 1))  // 1s, 2s, 4s
                    let jitter = Double.random(in: 0...0.5)
                    let delay = baseDelay + jitter
                    FileHandle.standardError.write(Data(
                        "[Consolidator] LLM attempt \(attempt)/\(maxAttempts) 失败: \(error.localizedDescription)，\(String(format: "%.1f", delay))s 后重试\n".utf8))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? LLMRetryError.exhausted
    }

    public enum LLMRetryError: Error, LocalizedError {
        case exhausted
        public var errorDescription: String? {
            "LLM call exhausted all retry attempts"
        }
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
        let answer = try await callLLMWithRetry(system: system, user: user)
        // P3-5 follow-up: 走 StructuredParser 拿 VerifyResponse.verdict.
        // 失败 fallback 老 keyword 解析 (Ollama 真实模型偶尔 schema 出格, 老路径兜底).
        return Self.parseVerifyAnswer(answer)
    }

    /// P3-5 follow-up: 解析 LLM 输出的 verify 判定.
    /// 优先 StructuredParser 拿 `VerifyResponse` (YES/NO enum 约束).
    /// 失败 fallback 老 `contains("YES")` keyword 解析 (跟老实现兼容).
    public static func parseVerifyAnswer(_ answer: String) -> Bool {
        if let verified = try? StructuredParser.parse(answer, as: VerifyResponse.self, schema: .verify) {
            return verified.verdict == .yes
        }
        // fallback: keyword 解析 (老路径, 跟 P3-2 否定词窗口同款容错)
        return answer.uppercased().contains("YES")
    }

    /// 完整流水线：原始候选教训 → 经四闸过滤后的可信教训
    /// 闸门 0（脱敏）→ 1（有来源）→ 3（回读校验）→ 2（分级）
    public func consolidate(_ raw: [Memory], rejectedFabricated: inout Int) async throws -> [Memory] {
        var out: [Memory] = []
        for var m in raw {
            if config.redactBeforeConsolidate { m = redactor.redact(m) }  // 闸门 0
            guard hasSource(m) else { continue }            // 闸门 1
            // P0-3 假 excerpt 闸门 (2 步路径: candidate 自己 excerpt, 来自 Gatherer
            // 直接拷源文件, 通常通过; 但若用户改 raw 文件可能出问题 → 防御性拦)
            if !sourceContents.isEmpty {
                let firstSource = m.sources.first
                if let s = firstSource, !s.excerpt.isEmpty {
                    let gate = checkSourceRefGate(draftExcerpt: s.excerpt, draftFile: s.file)
                    rejectedFabricated += gate.rejectedCount
                    guard gate.passed else { continue }
                }
            }
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
        /// LLM 在 analyze 步推荐的 wiki 分类（架构文档第 1 节：entity/concept/synthesis）
        public var recommendedKind: String?

        public init(keyEntities: [String]? = nil,
                    keyConcepts: [String]? = nil,
                    tensionsWithExisting: [String]? = nil,
                    recommendedLessonTexts: [String]? = nil,
                    reasoning: String? = nil,
                    recommendedKind: String? = nil) {
            self.keyEntities = keyEntities
            self.keyConcepts = keyConcepts
            self.tensionsWithExisting = tensionsWithExisting
            self.recommendedLessonTexts = recommendedLessonTexts
            self.reasoning = reasoning
            self.recommendedKind = recommendedKind
        }

        // 容错访问：nil 给空集合
        public var entitiesSafe: [String] { keyEntities ?? [] }
        public var conceptsSafe: [String] { keyConcepts ?? [] }
        public var tensionsSafe: [String] { tensionsWithExisting ?? [] }
        public var lessonsSafe: [String] { recommendedLessonTexts ?? [] }
        public var reasoningSafe: String { reasoning ?? "" }
        /// 安全访问 recommendedKind：解析失败时回退到默认
        public var kindSafe: MemoryKind {
            MemoryKind(rawValue: (recommendedKind ?? "").lowercased()) ?? MemoryKind.defaultKind
        }
    }

    /// generate 步 LLM 输出的"候选 Memory 草稿"（已带 source 引用 + decayClass 建议）
    /// 同样字段全 Optional 以容错
    public struct MemoryDraft: Codable, Equatable {
        public var text: String?
        public var sourceFile: String?
        public var sourceLine: Int?
        public var sourceExcerpt: String?
        public var decayClassRaw: String?
        /// LLM 推荐的 wiki 分类：entity / concept / synthesis。无法识别时 fallback 到 defaultKind。
        public var kindRaw: String?

        public init(text: String? = nil, sourceFile: String? = nil,
                    sourceLine: Int? = nil, sourceExcerpt: String? = nil,
                    decayClassRaw: String? = nil, kindRaw: String? = nil) {
            self.text = text
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
            self.sourceExcerpt = sourceExcerpt
            self.decayClassRaw = decayClassRaw
            self.kindRaw = kindRaw
        }

        public var textSafe: String { text ?? "" }
        public var sourceFileSafe: String { sourceFile ?? "" }
        public var sourceLineSafe: Int { sourceLine ?? 0 }
        public var sourceExcerptSafe: String { sourceExcerpt ?? "" }
        public var decayClassSafe: DecayClass {
            DecayClass(rawValue: decayClassRaw ?? "") ?? .normal
        }
        /// 解析 LLM 输出的 kind 字符串，无法识别时回退到默认（向后兼容旧 LLM 输出）
        public var kindSafe: MemoryKind {
            MemoryKind(rawValue: (kindRaw ?? "").lowercased()) ?? MemoryKind.defaultKind
        }
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
         "recommendedLessonTexts":[...], "reasoning":"...",
         "recommendedKind":"entity|concept|synthesis"}
        - keyEntities: 文中提到的关键实体（人/项目/工具/概念名）
        - keyConcepts: 抽象概念或模式
        - tensionsWithExisting: 与已知知识可能的矛盾点（无则空数组）
        - recommendedLessonTexts: 推荐提炼出的教训文本（每条 1 句，不超 80 字）
        - reasoning: 你的推理过程（让人能审查）
        - recommendedKind: 推荐本页放到 wiki/ 哪个分类。
            entity = 具体的人/项目/工具；concept = 抽象模式/规则；
            synthesis = 跨多个 entity/concept 的整合。
        """
        let user = """
        候选观察文本：
        \(candidate.text)

        来源片段：
        \(evidence)

        请按 JSON 格式输出你的分析。
        """
        let raw = try await callLLMWithRetry(system: system, user: user)
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
         "decayClassRaw":"slow|normal|fast", "kind":"entity|concept|synthesis"}
        - text: 1 句话教训，≤80 字
        - sourceFile/sourceLine/sourceExcerpt: 必须从下面"来源片段"里选一个真实存在
          的引用，**禁止编造**
        - decayClassRaw: slow=架构/长期决策、normal=通用教训、fast=临时观察/bug
        - kind: wiki 分类 — entity=具体人/项目/工具, concept=抽象模式/规则,
          synthesis=跨多个 entity/concept 的整合页；拿不准就回 fallback "concept"
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
        let raw = try await callLLMWithRetry(system: system, user: user)
        return try Self.parseDrafts(raw)
    }

    /// Three-Step 完整流水线：对每个 raw 候选走 3 步，最后返回通过 verify 的 Memory 列表
    ///
    /// 并发：多个 candidates 之间用 TaskGroup 并发（同一 candidate 内 analyze →
    /// generate → verify 是依赖链，不能并发）。上限由 config.concurrency 控制。
    /// P0-3: rejectedFabricated inout 累加器. **串行路径用 inout 累加**; 并发路径因 escaping
    /// closure 不能 capture inout, 改回 in-memory Atomic 计数器.
    public func consolidate3Step(
        _ raw: [Memory],
        consolidate2StepFallback: Bool? = nil,
        rejectedFabricated: inout Int
    ) async throws -> [Memory] {
        let fallback = consolidate2StepFallback ?? config.fallbackOnThreeStepFailure
        let limit = max(1, min(4, config.concurrency))  // P3-T2: cap 4 防 OOM

        // 并发上限 1 = 完全串行（等价旧行为），跳过 TaskGroup
        if limit <= 1 {
            return try await consolidate3StepSerial(raw, fallback: fallback, rejectedFabricated: &rejectedFabricated)
        }

        // 并发路径: 用 final class 计数器 (escaping closure 安全)
        let counter = CounterBox()
        return try await withThrowingTaskGroup(of: [Memory].self) { group in
            var iter = raw.makeIterator()
            var inflight = 0
            var collected: [Memory] = []

            // 用一个 semaphore-style 模式：保持 ≤ limit 个任务在跑
            func addNext() {
                guard let m = iter.next() else { return }
                inflight += 1
                group.addTask { [self] in
                    do {
                        var localCount = 0
                        let result = try await self.consolidate3StepOne(m, fallback: fallback, rejectedFabricated: &localCount)
                        counter.add(localCount)
                        return result
                    } catch {
                        // P3-3 评审 §1.2 修复: 3 段失败**不**回退 2 步 (那把全文当教训污染 ledger).
                        // 单条 candidate 失败时跳过, 记到 firstError, 整批继续. 失败的 candidate
                        // 留明晚重试 (因为它的 raw/ 没被标 processed, 下次 gather 会重新收集).
                        // 设计取舍: 不在 DreamCycle 暴露 "deferred" 计数, onStage 已经会报
                        // "consolidate failed" 1 次; 真实部署看 dream-report 跟 log 知道哪些 skip.
                        counter.addError(error)  // 失败计数 (可观测, 调试用)
                        return []
                    }
                }
            }
            for _ in 0..<limit { addNext() }

            while inflight > 0 {
                let batch = try await group.next()!
                collected.append(contentsOf: batch)
                inflight -= 1
                addNext()
            }
            // fallback=false 模式：concurrency=1 时错误会自然抛出（serial 不吞错）。
            // concurrency>1 时 firstError 标记首个错误，但只警告，不抛（保护整批）。
            if let firstErrorDescription = counter.firstErrorDescription(), fallback == false {
                // serial 模式下已经 throw，这里只会在 concurrency>1 时进。
                // 用户要 hard-fail 的语义应通过 concurrency=1 实现。
                FileHandle.standardError.write(Data(
                    "[Consolidator] 三段失败 (fallback=false 但吞掉以保护整批): \(firstErrorDescription)\n".utf8))
            }
            // P0-3: 并发路径回填 inout 计数
            rejectedFabricated += counter.value()
            return collected
        }
    }



    /// P0-3 helper: 并发路径 in-memory 计数器 (escaping closure 不能 capture inout)

    /// P0-3 helper: 并发路径 in-memory 计数器 (escaping closure 不能 capture inout)
    private final class CounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int = 0
        private var errors: Int = 0  // P3-3: 3 段失败计数
        private var firstErrorText: String?

        func add(_ n: Int) {
            lock.withLock { v += n }
        }

        func addError(_ error: Error) {
            lock.withLock {
                errors += 1
                if firstErrorText == nil {
                    firstErrorText = String(describing: error)
                }
            }
        }

        func value() -> Int {
            lock.withLock { v }
        }

        func firstErrorDescription() -> String? {
            lock.withLock { firstErrorText }
        }
    }

    /// 三段式串行版本（concurrency=1 时用，调试/回归用）
    private func consolidate3StepSerial(_ raw: [Memory], fallback: Bool,
                                         rejectedFabricated: inout Int) async throws -> [Memory] {
        var out: [Memory] = []
        for m in raw {
            out.append(contentsOf: try await consolidate3StepOne(m, fallback: fallback, rejectedFabricated: &rejectedFabricated))
        }
        return out
    }

    /// 三段式处理单个 candidate（含脱敏 + 来源真实性闸 + verify + fallback）。
    /// 失败时按 fallback 决定是回退到 2 步还是重新抛出。
    /// P0-3: rejectedFabricated 是 inout 累加器 (并发安全, 调用方传)
    func consolidate3StepOne(_ m: Memory, fallback: Bool,
                             rejectedFabricated: inout Int) async throws -> [Memory] {
        var mem = m
        if config.redactBeforeConsolidate { mem = redactor.redact(mem) }
        guard hasSource(mem) else { return [] }
        do {
            let analysis = try await analyze(mem)
            let drafts = try await generate(candidate: mem, analysis: analysis)
            // analyze 推荐的 kind（draft 自身 kindRaw 没值时回退到这里）
            let analysisKind = analysis.kindSafe
            var out: [Memory] = []
            for d in drafts {
                let text = d.textSafe
                guard !text.isEmpty else { continue }
                let draftSource = SourceRef(
                    file: d.sourceFileSafe,
                    line: d.sourceLineSafe,
                    excerpt: d.sourceExcerptSafe
                )
                // 来源真实性闸：sourceFile 必须与原 candidate 的 source 同文件
                guard mem.sources.contains(where: { $0.file == d.sourceFileSafe })
                else { continue }
                // P0-3: 假 excerpt 闸门 (确定性, 0 LLM).
                // draft.sourceExcerpt 归一化后必须真在源文件里, 否则 fabricated.
                // 跟 mem.sources[0].excerpt 同样长度的 excerpt 由 Gatherer 直接来自源文件,
                // 所以这条闸门**只在 LLM 生成的 excerpt 偏离真实内容时**触发.
                if !sourceContents.isEmpty {
                    let gate = checkSourceRefGate(draftExcerpt: d.sourceExcerptSafe,
                                                  draftFile: d.sourceFileSafe)
                    rejectedFabricated += gate.rejectedCount
                    guard gate.passed else { continue }
                }
                // 优先级：draft 自己给的 kindRaw > analyze 推荐的 > 默认 concept
                let resolvedKind: MemoryKind = {
                    if let raw = d.kindRaw, !raw.isEmpty,
                       let k = MemoryKind(rawValue: raw.lowercased()) { return k }
                    return analysisKind
                }()
                let draft = Memory(
                    text: text,
                    sources: [draftSource],
                    decayClass: d.decayClassSafe,
                    kind: resolvedKind
                )
                guard try await verify(draft) else { continue }
                var accepted = draft
                accepted.status = classify(accepted)
                out.append(accepted)
            }
            return out
        } catch {
            if fallback {
                // P3-3 评审 §1.2 修复: 老行为 "回退 2 步" 把全文当教训污染 ledger.
                // 新行为: 仍允许 2 步 fallback, 但仅当 config 显式开 + mock provider 时
                // (生产环境默认 fallback=false, 3 段失败直接走 throw 让 DreamCycle 处理).
                return try await consolidate([mem], rejectedFabricated: &rejectedFabricated)
            }
            // P3-3: 3 段失败, 不回退 2 步, 抛错让 DreamCycle 跳过该 candidate (留明晚重试)
            throw error
        }
    }

    /// 智能入口：根据 config.useThreeStepCoT 选择 3 段或 2 段。
    /// 这是 DreamCycle 应该调的主入口。
    /// P0-3: 返回值里含 rejectedFabricated 计数 (旧调用方忽略, DreamCycle 装 Outcome)
    public func consolidateSmart(_ raw: [Memory]) async throws -> (accepted: [Memory], rejectedFabricated: Int) {
        var rejectedFabricated = 0
        if config.useThreeStepCoT {
            let out = try await consolidate3Step(raw, rejectedFabricated: &rejectedFabricated)
            return (out, rejectedFabricated)
        }
        let out = try await consolidate(raw, rejectedFabricated: &rejectedFabricated)
        return (out, rejectedFabricated)
    }

    // MARK: - JSON 解析小工具（容错：LLM 偶尔会裹 markdown ```json``` 块）

    static func parseAnalysis(_ raw: String) throws -> Analysis {
        // P3-5 follow-up: 优先 StructuredParser 走 `AnalysisResponse` schema (analyze 阶段).
        // 失败 fallback 老路径 (跟 P3-5 schema 字段一致, 解析老格式 JSON 仍兼容).
        do {
            let response = try StructuredParser.parse(raw, as: AnalysisResponse.self, schema: .analyze)
            return Analysis(
                keyEntities: response.keyEntities,
                keyConcepts: response.keyConcepts,
                tensionsWithExisting: response.tensionsWithExisting,
                recommendedLessonTexts: response.recommendedLessonTexts,
                reasoning: response.reasoning,
                recommendedKind: response.recommendedKind
            )
        } catch {
            // fallback: 老 Analysis 字段完全一致, 走老解析兜底
            let cleaned = stripMarkdownFence(raw)
            guard let data = cleaned.data(using: .utf8),
                  let a = try? JSONDecoder().decode(Analysis.self, from: data) else {
                throw Consolidate3StepError.analysisParseFailed(cleaned.prefix(200).description)
            }
            return a
        }
    }

    static func parseDrafts(_ raw: String) throws -> [MemoryDraft] {
        // P3-5 follow-up: 优先 StructuredParser 走 `DraftListResponse` schema (generate 阶段).
        // 失败 fallback 老路径 (跟老 MemoryDraft 字段兼容, 解析老格式 JSON).
        do {
            let response = try StructuredParser.parse(raw, as: DraftListResponse.self, schema: .generate)
            let drafts = (response.drafts ?? []).map { item in
                MemoryDraft(
                    text: item.text,
                    sourceFile: item.sourceFile,
                    sourceLine: item.sourceLine,
                    sourceExcerpt: item.sourceExcerpt,
                    decayClassRaw: item.decayClassRaw,
                    kindRaw: item.kind
                )
            }
            return drafts
        } catch {
            // fallback: 老解析 (容错数组/对象)
            let cleaned = stripMarkdownFence(raw)
            guard let data = cleaned.data(using: .utf8) else {
                throw Consolidate3StepError.draftsParseFailed(cleaned.prefix(200).description)
            }
            if let arr = try? JSONDecoder().decode([MemoryDraft].self, from: data) {
                return arr
            }
            if let obj = try? JSONDecoder().decode(DraftEnvelope.self, from: data) {
                return obj.drafts ?? []
            }
            throw Consolidate3StepError.draftsParseFailed(cleaned.prefix(200).description)
        }
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
        var rejectedFabricated = 0
        let accepted = try await consolidate(raw, rejectedFabricated: &rejectedFabricated)
        var detector = ContradictionDetector(llm: llm)
        let linked = try await detector.link(candidates: accepted, against: existing)
        return (linked.candidates, linked.existing)
    }
}
