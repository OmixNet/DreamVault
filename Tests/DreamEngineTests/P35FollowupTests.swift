import XCTest
@testable import DreamEngine

/// P3-5 follow-up 评审 §4.2 修复: 把 4 个老 keyword 解析调用切到 StructuredParser
/// 走 4 schema 之一 (verify / conflict / analyze / generate). 老 keyword 路径保留
/// 作 fallback (Ollama 真实模型偶尔 schema 出格, 老路径兜底).
///
/// 4 切点:
/// 1. Consolidator.parseVerifyAnswer (verify 阶段) — 优先 VerifyResponse, fallback keyword
/// 2. ContradictionDetector.parseConflictAnswer (conflict 阶段) — 优先 ConflictResponse, fallback keyword
/// 3. Consolidator.parseAnalysis (analyze 阶段) — 优先 AnalysisResponse, fallback 老 Analysis
/// 4. Consolidator.parseDrafts (generate 阶段) — 优先 DraftListResponse, fallback 老 MemoryDraft
///
/// 关键 invariant:
/// - 老 keyword 输入 ("YES" / "NO" / "CONFLICT" / "OK" 关键词) 仍正确解析 (向后兼容)
/// - 新 JSON schema 输入 ({"verdict":"YES"}) 正确解析 (主路径)
/// - 真 LLM 偶尔出格 (markdown 围栏 / 杂糅 / 大小写不一致) 走 StructuredParser 仍能解析
/// - fallback keyword 路径: 真出格 (JSON 损坏) 才走, 老测试 case 不退化
final class P35FollowupTests: XCTestCase {

    // MARK: - 切点 1: Consolidator.parseVerifyAnswer

    /// 1. 主路径: JSON schema 输入 ({"verdict":"YES"}) 走 StructuredParser
    func testVerifyAnswer_jsonYES_yes() {
        let r = Consolidator.parseVerifyAnswer(#"{"verdict":"YES","reasoning":"证据充分"}"#)
        XCTAssertTrue(r, "JSON schema YES 应解析为 true")
    }

    /// 2. 主路径: JSON schema NO
    func testVerifyAnswer_jsonNO_false() {
        let r = Consolidator.parseVerifyAnswer(#"{"verdict":"NO","reasoning":"证据不足"}"#)
        XCTAssertFalse(r, "JSON schema NO 应解析为 false")
    }

    /// 3. fallback: 老 keyword "YES" 仍正确
    func testVerifyAnswer_keywordYES_yes() {
        let r = Consolidator.parseVerifyAnswer("YES")
        XCTAssertTrue(r)
    }

    /// 4. fallback: 老 keyword "NO" 仍正确
    func testVerifyAnswer_keywordNO_false() {
        let r = Consolidator.parseVerifyAnswer("NO")
        XCTAssertFalse(r)
    }

    /// 5. fallback: 杂糅 (出格) → 走 keyword 兜底
    func testVerifyAnswer_messyFallsBackToKeyword() {
        let r = Consolidator.parseVerifyAnswer("思考... 最终答案是 YES 因为证据充分")
        XCTAssertTrue(r, "杂糅文本应走 keyword 兜底")
    }

    // MARK: - 切点 2: ContradictionDetector.parseConflictAnswer

    /// 6. 主路径: JSON schema CONFLICT
    func testConflictAnswer_jsonCONFLICT_true() {
        let r = ContradictionDetector.parseConflictAnswer(#"{"verdict":"CONFLICT","reasoning":"主题相同结论相反"}"#)
        XCTAssertTrue(r)
    }

    /// 7. 主路径: JSON schema OK
    func testConflictAnswer_jsonOK_false() {
        let r = ContradictionDetector.parseConflictAnswer(#"{"verdict":"OK","reasoning":"主题不同"}"#)
        XCTAssertFalse(r)
    }

    /// 8. 主路径: JSON schema AMBIGUOUS
    func testConflictAnswer_jsonAMBIGUOUS_false() {
        let r = ContradictionDetector.parseConflictAnswer(#"{"verdict":"AMBIGUOUS","reasoning":"信息不全"}"#)
        XCTAssertFalse(r, "AMBIGUOUS 不算矛盾")
    }

    /// 9. P3-2 修复 invariant: "NO CONFLICT" 仍判 false (主路径 + 老路径都 OK)
    func testConflictAnswer_noConflict_false() {
        let r = ContradictionDetector.parseConflictAnswer("NO CONFLICT")
        XCTAssertFalse(r, "P3-2 修复: NO CONFLICT 不应判为矛盾")
    }

    /// 10. 老 keyword 路径: "CONFLICT" 仍判 true
    func testConflictAnswer_keywordCONFLICT_true() {
        let r = ContradictionDetector.parseConflictAnswer("CONFLICT")
        XCTAssertTrue(r)
    }

    /// 11. 老 JSON 格式: {"conflict": false} 仍判 false (P3-2 老路径兼容)
    func testConflictAnswer_legacyJSON_false() {
        let r = ContradictionDetector.parseConflictAnswer(#"{"conflict": false}"#)
        XCTAssertFalse(r, "P3-2 老 JSON 格式仍兼容")
    }

    // MARK: - 切点 3: Consolidator.parseAnalysis

    /// 12. 主路径: AnalysisResponse JSON
    func testParseAnalysis_jsonSchema() throws {
        let raw = #"{"keyEntities":["SwiftUI","AppKit"],"keyConcepts":["macOS UI"],"reasoning":"OK","recommendedKind":"concept"}"#
        let a = try Consolidator.parseAnalysis(raw)
        XCTAssertEqual(a.entitiesSafe, ["SwiftUI", "AppKit"])
        XCTAssertEqual(a.conceptsSafe, ["macOS UI"])
        XCTAssertEqual(a.kindSafe, .concept)
    }

    /// 13. fallback: 老 Analysis 格式仍兼容
    func testParseAnalysis_legacyFormat() throws {
        let raw = #"{"keyEntities":["legacy"],"keyConcepts":[],"reasoning":"","recommendedKind":"entity"}"#
        let a = try Consolidator.parseAnalysis(raw)
        XCTAssertEqual(a.entitiesSafe, ["legacy"])
        XCTAssertEqual(a.kindSafe, .entity)
    }

    /// 14. 损坏 JSON 抛错
    func testParseAnalysis_corruptedThrows() {
        XCTAssertThrowsError(try Consolidator.parseAnalysis("not json at all"))
    }

    // MARK: - 切点 4: Consolidator.parseDrafts

    /// 15. 主路径: DraftListResponse JSON (object with drafts)
    func testParseDrafts_jsonObject() throws {
        let raw = #"{"drafts":[{"text":"D1","sourceFile":"raw/a.md","sourceLine":10,"sourceExcerpt":"excerpt","decayClassRaw":"normal","kind":"entity"}]}"#
        let d = try Consolidator.parseDrafts(raw)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].textSafe, "D1")
        XCTAssertEqual(d[0].sourceFileSafe, "raw/a.md")
        XCTAssertEqual(d[0].sourceLineSafe, 10)
        XCTAssertEqual(d[0].decayClassSafe, .normal)
        XCTAssertEqual(d[0].kindSafe, .entity)
    }

    /// 16. fallback: 老格式 (array 直接) 仍兼容
    func testParseDrafts_legacyArray() throws {
        let raw = #"[{"text":"D2","sourceFile":"raw/b.md","sourceExcerpt":"excerpt","kind":"concept"}]"#
        let d = try Consolidator.parseDrafts(raw)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].textSafe, "D2")
        XCTAssertEqual(d[0].kindSafe, .concept)
    }

    /// 17. 损坏 JSON 抛错
    func testParseDrafts_corruptedThrows() {
        XCTAssertThrowsError(try Consolidator.parseDrafts("not json"))
    }

    // MARK: - 端到端: 走 Consolidator 真实路径

    /// 18. 真实 verify 路径 (Consolidator.verify) 走主路径 StructuredParser
    func testConsolidator_verify_stubLLM_usesStructuredParser() async throws {
        // 假装 LLM 返 JSON 格式 (Ollama 真模型走 schema 约束时)
        let stubLLM = MockLLMProvider { _, _ in
            #"{"verdict":"YES","reasoning":"stub"}"#
        }
        let c = Consolidator(llm: stubLLM, config: .init(durableMinSources: 1, redactBeforeConsolidate: false))
        let m = Memory(
            id: "t1", text: "test lesson",
            sources: [SourceRef(file: "raw/test.md", line: 1, excerpt: "excerpt")],
            status: .candidate, createdAt: Date(), lastAccess: Date(),
            reinforceCount: 0, inboundLinks: 0, contradicts: [],
            decayClass: .normal, kind: .entity, relatedTo: []
        )
        let passed = try await c.verify(m)
        XCTAssertTrue(passed, "verify 走 StructuredParser 主路径应判 YES")
    }
}
