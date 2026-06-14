import XCTest
@testable import DreamEngine

/// Three-Step CoT Consolidator 测试
///
/// 测：analyze 步 JSON 解析、generate 步 JSON 解析、3 段完整流程、fallback 到 2 段、来源真实性闸。
final class Consolidator3StepTests: XCTestCase {

    // MARK: - 测试 LLM：分阶段返回不同 JSON

    /// 简易多阶段 mock：按 system prompt 关键词分发
    /// final class 而非 struct —— 因为我们要在 protocol 的 non-mutating
    /// complete() 里修改 callCount，struct 会触发 "left side of mutating
    /// operator isn't mutable" 编译错。
    final class StagedLLM: LLMProvider, @unchecked Sendable {
        var analysisJSON: String
        var draftsJSON: String
        var verifyAnswer: String = "YES"   // 默认 verify 通过
        /// 累计调用次数（多线程访问需要 lock）
        private let _lock = NSLock()
        private var _callCount: Int = 0
        var callCount: Int {
            _lock.withLock { _callCount }
        }

        init(analysisJSON: String, draftsJSON: String, verifyAnswer: String = "YES") {
            self.analysisJSON = analysisJSON
            self.draftsJSON = draftsJSON
            self.verifyAnswer = verifyAnswer
        }

        func complete(system: String, user: String) async throws -> String {
            _lock.withLock { _callCount += 1 }
            if system.contains("分析师") { return analysisJSON }
            if system.contains("提炼员") { return draftsJSON }
            if system.contains("事实校验器") { return verifyAnswer }
            return "YES"
        }
    }

    func makeCandidate(text: String = "决定用 SwiftUI 构建新 macOS 应用 UI", file: String = "raw/a.md") -> Memory {
        Memory(
            text: text,
            sources: [SourceRef(file: file, line: 1, excerpt: "the raw observation")]
        )
    }

    // MARK: - analyze

    func testAnalyze_parsesStructuredJSON() async throws {
        let llm = StagedLLM(
            analysisJSON: """
            {"keyEntities":["SwiftUI","macOS"], "keyConcepts":["前端框架选型"],
             "tensionsWithExisting":[], "recommendedLessonTexts":["倾向用 SwiftUI"],
             "reasoning":"文内直接提到 SwiftUI"}
            """,
            draftsJSON: "[]"
        )
        let c = Consolidator(llm: llm)
        let a = try await c.analyze(makeCandidate())
        XCTAssertEqual(a.entitiesSafe, ["SwiftUI", "macOS"])
        XCTAssertEqual(a.conceptsSafe, ["前端框架选型"])
        XCTAssertEqual(a.tensionsSafe, [])
        XCTAssertEqual(a.lessonsSafe, ["倾向用 SwiftUI"])
        XCTAssertFalse(a.reasoningSafe.isEmpty)
    }

    func testAnalyze_stripsMarkdownFence() async throws {
        // LLM 偶发会包 ```json ... ```
        let llm = StagedLLM(
            analysisJSON: """
            ```json
            {"keyEntities":["X"], "keyConcepts":[], "tensionsWithExisting":[],
             "recommendedLessonTexts":[], "reasoning":"x"}
            ```
            """,
            draftsJSON: "[]"
        )
        let c = Consolidator(llm: llm)
        let a = try await c.analyze(makeCandidate())
        XCTAssertEqual(a.entitiesSafe, ["X"])
    }

    func testAnalyze_rejectsMalformedJSON() async throws {
        let llm = StagedLLM(analysisJSON: "not json at all", draftsJSON: "[]")
        let c = Consolidator(llm: llm)
        do {
            _ = try await c.analyze(makeCandidate())
            XCTFail("应该解析失败")
        } catch {
            // 期望抛 Consolidate3StepError.analysisParseFailed
        }
    }

    // MARK: - generate

    func testGenerate_parsesDraftArray() async throws {
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [{"text":"偏好 SwiftUI", "sourceFile":"raw/a.md", "sourceLine":1,
              "sourceExcerpt":"the raw observation", "decayClassRaw":"slow"}]
            """
        )
        let c = Consolidator(llm: llm)
        let analysis = Consolidator.Analysis()
        let drafts = try await c.generate(candidate: makeCandidate(), analysis: analysis)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].text, "偏好 SwiftUI")
        XCTAssertEqual(drafts[0].sourceFile, "raw/a.md")
        XCTAssertEqual(drafts[0].decayClassRaw, "slow")
    }

    func testGenerate_acceptsEnvelopeShape() async throws {
        // LLM 可能返回 {"drafts": [...]} 形式
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            {"drafts":[{"text":"x", "sourceFile":"raw/a.md", "sourceLine":1,
                          "sourceExcerpt":"the raw observation", "decayClassRaw":""}]}
            """
        )
        let c = Consolidator(llm: llm)
        let drafts = try await c.generate(candidate: makeCandidate(),
                                          analysis: Consolidator.Analysis())
        XCTAssertEqual(drafts.count, 1)
    }

    func testGenerate_emptyArrayOK() async throws {
        let llm = StagedLLM(analysisJSON: "{}", draftsJSON: "[]")
        let c = Consolidator(llm: llm)
        let drafts = try await c.generate(candidate: makeCandidate(),
                                          analysis: Consolidator.Analysis())
        XCTAssertTrue(drafts.isEmpty)
    }

    // MARK: - 3 段完整流程

    func testConsolidate3Step_endToEnd_oneAccepted() async throws {
        let llm = StagedLLM(
            analysisJSON: """
            {"keyEntities":["SwiftUI"], "keyConcepts":[],
             "tensionsWithExisting":[], "recommendedLessonTexts":["用 SwiftUI"],
             "reasoning":"good"}
            """,
            draftsJSON: """
            [{"text":"倾向用 SwiftUI", "sourceFile":"raw/a.md", "sourceLine":1,
              "sourceExcerpt":"the raw observation", "decayClassRaw":"slow"}]
            """
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], rejectedFabricated: &cnt)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "倾向用 SwiftUI")
        XCTAssertEqual(out[0].decayClass, .slow, "应解析 decayClass=slow")
        XCTAssertEqual(out[0].sources.first?.file, "raw/a.md")
    }

    func testConsolidate3Step_dropsWhenVerifyFails() async throws {
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [{"text":"x", "sourceFile":"raw/a.md", "sourceLine":1,
              "sourceExcerpt":"the raw observation", "decayClassRaw":""}]
            """,
            verifyAnswer: "NO"   // verify 不通过
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], rejectedFabricated: &cnt)
        XCTAssertTrue(out.isEmpty, "verify NO 应丢弃")
    }

    func testConsolidate3Step_dropsHallucinatedSource() async throws {
        // LLM 试图引用一个不在 raw 候选里的文件
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [{"text":"x", "sourceFile":"raw/HALLUCINATED.md", "sourceLine":1,
              "sourceExcerpt":"x", "decayClassRaw":""}]
            """
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate(file: "raw/a.md")], rejectedFabricated: &cnt)
        XCTAssertTrue(out.isEmpty, "编造的 source 应被来源真实性闸拦截")
    }

    func testConsolidate3Step_keepsNoSourceDraft() async throws {
        // generate 出来但 text 为空 → 跳过
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [{"text":"", "sourceFile":"raw/a.md", "sourceLine":1,
              "sourceExcerpt":"x", "decayClassRaw":""}]
            """
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], rejectedFabricated: &cnt)
        XCTAssertTrue(out.isEmpty)
    }

    func testConsolidate3Step_unknownDecayClassFallsBackToNormal() async throws {
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [{"text":"x", "sourceFile":"raw/a.md", "sourceLine":1,
              "sourceExcerpt":"the raw observation", "decayClassRaw":"unknown-thing"}]
            """
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], rejectedFabricated: &cnt)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].decayClass, .normal)
    }

    func testConsolidate3Step_multipleDraftsFromOneRaw() async throws {
        // 一个 raw 候选产生多个 draft（LLM 一稿多投）
        let llm = StagedLLM(
            analysisJSON: "{}",
            draftsJSON: """
            [
              {"text":"教训 A", "sourceFile":"raw/a.md", "sourceLine":1,
               "sourceExcerpt":"the raw observation", "decayClassRaw":"slow"},
              {"text":"教训 B", "sourceFile":"raw/a.md", "sourceLine":1,
               "sourceExcerpt":"the raw observation", "decayClassRaw":"fast"}
            ]
            """
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], rejectedFabricated: &cnt)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0.decayClass }, [.slow, .fast])
    }

    func testConsolidate3Step_fallsBackTo2StepWhenAnalyzeFails() async throws {
        // analyze 步 JSON 解析失败 → 触发 fallback → 用旧 2 段逻辑
        // 旧逻辑里 MockLLM 不走 analyze/generate，只是 verify(staged LLM
        // 对 verify 关键词 system 返回 "YES")
        let llm = StagedLLM(
            analysisJSON: "definitely not json",  // 故意 parse 失败
            draftsJSON: "[]"
        )
        let c = Consolidator(llm: llm)
        var cnt = 0; let out = try await c.consolidate3Step([makeCandidate()], consolidate2StepFallback: true, rejectedFabricated: &cnt)
        // 2 段逻辑：verify(staged LLM 的 system "事实校验器" → verifyAnswer "YES") → 通过
        // 但 candidate.status = classify() 决定，distinctSourceCount=1 → candidate
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, .candidate)
    }

    func testConsolidate3Step_noFallbackHardFails() async throws {
        let llm = StagedLLM(analysisJSON: "bad json", draftsJSON: "[]")
        // concurrency=1 走 serial 模式，错误会自然抛出（fallback=false 时 hard-fail 语义）
        let c = Consolidator(llm: llm, config: ConsolidationConfig(concurrency: 1))
        do {
            var cnt = 0; _ = try await c.consolidate3Step([makeCandidate()], consolidate2StepFallback: false, rejectedFabricated: &cnt)
            XCTFail("应抛错而不是悄悄通过")
        } catch {
            // 期望
        }
    }

    /// 并发：10 个候选 + concurrency=4，应该并发处理（callCount 累计到 ≥10 次 LLM 调用）
    func testConsolidate3Step_concurrentProcessesAllCandidates() async throws {
        let llm = StagedLLM(analysisJSON: #"{"reasoning":"ok","entities":[],"contradictions":[],"lessons":[]}"#,
                            draftsJSON: "[]",
                            verifyAnswer: "YES")
        let c = Consolidator(llm: llm,
                             config: ConsolidationConfig(concurrency: 4))
        let candidates = (1...10).map { i in
            makeCandidate(text: "候选 #\(i)", file: "raw/\(i).md")
        }
        var cnt = 0; let out = try await c.consolidate3Step(candidates, rejectedFabricated: &cnt)
        // 至少应该有 10 次 LLM 调用（每个 candidate 至少 analyze 1 次）
        XCTAssertGreaterThanOrEqual(llm.callCount, 10, "10 个候选应至少调 LLM 10 次")
        XCTAssertGreaterThanOrEqual(out.count, 0)  // draftsJSON=[] 可能没有 accepted，但流程跑完
    }

    /// 并发：concurrency=1 等价于串行，所有候选都处理
    func testConsolidate3Step_serialConcurrency1_processesAll() async throws {
        let llm = StagedLLM(analysisJSON: #"{"reasoning":"ok","entities":[],"contradictions":[],"lessons":[]}"#,
                            draftsJSON: "[]",
                            verifyAnswer: "YES")
        let c = Consolidator(llm: llm,
                             config: ConsolidationConfig(concurrency: 1))
        let candidates = (1...5).map { i in makeCandidate(text: "x\(i)", file: "raw/\(i).md") }
        var cnt = 0; _ = try await c.consolidate3Step(candidates, rejectedFabricated: &cnt)
        XCTAssertGreaterThanOrEqual(llm.callCount, 5)
    }

    /// consolidateSmart 根据 config 路由
    func testConsolidateSmart_routesByConfig() async throws {
        let llm = StagedLLM(analysisJSON: #"{"reasoning":"ok","entities":[],"contradictions":[],"lessons":[]}"#,
                            draftsJSON: "[]",
                            verifyAnswer: "YES")
        // useThreeStepCoT=true 走 3 段路径。
        // 这里 generate 会返回 []（空 drafts），所以流程只跑 analyze + generate = 2 次 LLM 调用。
        // 想测到 verify 调用就得给一个非空 draftsJSON。
        let c3 = Consolidator(llm: llm,
                              config: ConsolidationConfig(useThreeStepCoT: true, concurrency: 1))
        let r3 = try await c3.consolidateSmart([makeCandidate()]); _ = r3.accepted; _ = r3.rejectedFabricated
        let threeStepCount = llm.callCount
        XCTAssertGreaterThanOrEqual(threeStepCount, 2, "3 段 CoT 至少 analyze + generate = 2 次 LLM 调用")

        // useThreeStepCoT=false 走 2 段（每个候选只 verify 1 次）—— 用不同的 llm 实例避免 callCount 累加
        let llm2 = StagedLLM(analysisJSON: "", draftsJSON: "", verifyAnswer: "YES")
        let c2 = Consolidator(llm: llm2,
                              config: ConsolidationConfig(useThreeStepCoT: false, concurrency: 1))
        let r2 = try await c2.consolidateSmart([makeCandidate()]); _ = r2.accepted; _ = r2.rejectedFabricated
        XCTAssertEqual(llm2.callCount, 1, "2 步快速路径只 verify 1 次")
    }

    func testConsolidate3Step_redactsBeforeAnalyze() async throws {
        // raw 文本含 API key → redact 闸在 analyze 前跑 → LLM 看到的是脱敏文本
        // 用一个 capture LLM 验证 analyze 步收到的 user prompt 不含明文 key
        final class CaptureLLM: LLMProvider, @unchecked Sendable {
            var capturedByStep: [String: String] = [:]
            func complete(system: String, user: String) async throws -> String {
                if system.contains("分析师") {
                    capturedByStep["analyze"] = user
                    return """
                    {"keyEntities":[], "keyConcepts":[], "tensionsWithExisting":[],
                     "recommendedLessonTexts":[], "reasoning":"x"}
                    """
                }
                if system.contains("提炼员") {
                    capturedByStep["generate"] = user
                    return """
                    [{"text":"x", "sourceFile":"raw/a.md", "sourceLine":1,
                      "sourceExcerpt":"ok", "decayClassRaw":""}]
                    """
                }
                if system.contains("事实校验器") {
                    capturedByStep["verify"] = user
                }
                return "YES"
            }
        }
        let cap = CaptureLLM()
        let c = Consolidator(llm: cap, config: ConsolidationConfig(redactBeforeConsolidate: true))
        let mem = Memory(
            text: "今天发现 key 是 sk-live-abc123XYZ4567890abcd",
            sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "sk-live-abc123XYZ4567890abcd")]
        )
        // 走 3 段，redact 闸会先跑
        var cnt = 0; _ = try await c.consolidate3Step([mem], rejectedFabricated: &cnt)
        let analyzeUser = cap.capturedByStep["analyze"] ?? ""
        XCTAssertFalse(analyzeUser.contains("sk-live-abc123XYZ4567890abcd"),
                       "脱敏闸应已清掉明文 key，analyze 步 LLM 不应看到")
        XCTAssertTrue(analyzeUser.contains("REDACTED_API_KEY"),
                      "analyze 步 user prompt 应含 REDACTED_API_KEY 占位符")
    }
}
