import XCTest
@testable import DreamEngine

/// P0-1 矛盾检测预筛: 0 成本 LLM 漏斗
/// 验收 (spec): durable=500 + 新=10 时 ≤ 50 LLM 调用, 旧 contradiction test 全绿, 新增 ≥ 6 case
@MainActor
final class PrescreenerTests: XCTestCase {

    private func mem(_ id: String, _ text: String, sourceFile: String = "raw/note.md") -> Memory {
        Memory(
            id: id, text: text,
            sources: [SourceRef(file: sourceFile, line: 1, excerpt: String(text.prefix(50)))],
            status: .durable
        )
    }

    // MARK: - TextEntityTokens

    func testTextEntityTokens_extractsEnglishWords() {
        let tokens = TextEntityTokens.extract("Use SwiftUI and Combine for reactive programming")
        XCTAssertTrue(tokens.contains("swiftui"))
        XCTAssertTrue(tokens.contains("combine"))
        XCTAssertTrue(tokens.contains("reactive"))
        XCTAssertTrue(tokens.contains("programming"))
    }

    func testTextEntityTokens_extractsChineseChars() {
        let tokens = TextEntityTokens.extract("使用 SwiftUI 做界面")
        XCTAssertTrue(tokens.contains("使"))
        XCTAssertTrue(tokens.contains("界"))
        XCTAssertTrue(tokens.contains("面"))
        // 停用字 "用" 应被过滤
        XCTAssertFalse(tokens.contains("用"))
        XCTAssertFalse(tokens.contains("的"))
        // 不在停用字表的字保留
        XCTAssertTrue(tokens.contains("使"))
    }

    func testTextEntityTokens_filtersStopwords() {
        let tokens = TextEntityTokens.extract("The quick brown fox is a test")
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("is"))
        XCTAssertFalse(tokens.contains("a"))
        XCTAssertTrue(tokens.contains("quick"))
        XCTAssertTrue(tokens.contains("brown"))
        XCTAssertTrue(tokens.contains("test"))
    }

    // MARK: - Prescreener 行为

    func testPrescreen_skipsUnrelatedPair() {
        // 无 token 重合, 无图邻接 → 0 成本跳过
        let g = KnowledgeGraph()
        let p = Prescreener(maxPairsPerNight: 50, graph: g)
        let cands = [mem("c1", "在 SwiftUI 里用 NavigationStack")]
        let exist = [mem("e1", "PostgreSQL 用 pg_dump 备份")]
        let r = p.prescreen(candidates: cands, against: exist)
        XCTAssertEqual(r.toCompare.count, 0, "不相关应该被预筛淘汰")
        XCTAssertGreaterThan(r.skipped, 0)
    }

    func testPrescreen_keepsByTokenOverlap() {
        // 共享实体 token "swiftui" → 通过预筛
        let g = KnowledgeGraph()
        let p = Prescreener(maxPairsPerNight: 50, graph: g)
        let cands = [mem("c1", "SwiftUI 5 新增 NavigationStack API")]
        let exist = [mem("e1", "SwiftUI 4 用 NavigationView, 5 改了")]
        let r = p.prescreen(candidates: cands, against: exist)
        XCTAssertEqual(r.toCompare.count, 1, "共享 'swiftui' 应该进")
        XCTAssertEqual(r.toCompare[0].candidate.id, "c1")
        XCTAssertEqual(r.toCompare[0].existing.id, "e1")
    }

    func testPrescreen_keepsByAdamicAdar() {
        // 共享源文件 → KnowledgeGraph 加边 → Adamic-Adar > 0 → 进
        let sharedSrc = "raw/claude-coding.md"
        let cands = [mem("c1", "新事实: 用 appkit 比 swiftui 慢", sourceFile: sharedSrc)]
        let exist = [mem("e1", "旧事实: appkit 比 swiftui 慢", sourceFile: sharedSrc)]
        let g = KnowledgeGraph(memories: cands + exist)
        let p = Prescreener(maxPairsPerNight: 50, graph: g)
        let r = p.prescreen(candidates: cands, against: exist)
        XCTAssertEqual(r.toCompare.count, 1, "共享源文件 → Adamic-Adar > 0 → 进")
    }

    func testPrescreen_truncatesAtMaxPairsPerNight() {
        // 100 对都共享 token, maxPairsPerNight=10 → 只跑 10, 90 截断
        let g = KnowledgeGraph()
        let p = Prescreener(maxPairsPerNight: 10, graph: g)
        let cands = (0..<10).map { mem("c\($0)", "SwiftUI 主题") }
        let exist = (0..<10).map { mem("e\($0)", "SwiftUI 主题 副") }
        let r = p.prescreen(candidates: cands, against: exist)
        XCTAssertEqual(r.toCompare.count, 10, "truncate to 10")
        XCTAssertEqual(r.truncated, 90, "100 - 10 = 90 truncated")
        XCTAssertEqual(r.totalKeptByScreener, 100)
    }

    // MARK: - 端到端: durable=500 + 新=10 的真实成本验证 (spec 验收)

    func testEndToEnd_500Durable_10New_underLimit() {
        // 模拟 spec 的负载: 500 个 durable + 10 个新候选
        // 大部分无关, 偶尔几个共享 token
        let exist = (0..<500).map { i -> Memory in
            let t = i % 50 == 0 ? "SwiftUI 测试" : "无关事实 \(i)"
            return mem("e\(i)", t)
        }
        // 10 个候选: 5 个跟现有共享 token (要进 LLM), 5 个完全无关
        let cands: [Memory] = (0..<10).map { i -> Memory in
            if i < 5 {
                return mem("c\(i)", "SwiftUI 观点 c\(i)")
            } else {
                return mem("c\(i)", "Python 异步编程 c\(i)")
            }
        }
        let g = KnowledgeGraph()
        let p = Prescreener(maxPairsPerNight: 50, graph: g)
        let r = p.prescreen(candidates: cands, against: exist)
        // 5 个 SwiftUI 候选 × ~10 个 SwiftUI 现有 = 50 对共享 token, 全部进, 不超 50
        // 5 个 Python 候选 vs 500 个现有: 0 token 重合, 0 AA → 0 进
        XCTAssertLessThanOrEqual(r.toCompare.count, 50,
            "spec 验收: ≤ 50 LLM 调用 (实际 \(r.toCompare.count))")
        XCTAssertGreaterThan(r.toCompare.count, 0,
            "至少有 SwiftUI 共享的应该进 (实际 \(r.toCompare.count))")
        // 跟 500*10=5000 全比对相比, 节省 ≥ 99%
        let fullCompareCost = 500 * 10
        let savingsPct = Double(fullCompareCost - r.toCompare.count) / Double(fullCompareCost) * 100
        XCTAssertGreaterThan(savingsPct, 95,
            "节省 ≥ 95% (实际 \(String(format: "%.1f", savingsPct))%)")
    }

    // MARK: - 跟 ContradictionDetector 集成

    func testContradictionDetector_usesPrescreen_realLLMCalls() async throws {
        // 端到端: 走真实 ContradictionDetector.link(), 验证 lastLLMCalls == 预筛保留数 (因为全 LLM 调用都跑, 无漏)
        let g = KnowledgeGraph()
        var d = ContradictionDetector(llm: MockLLMProvider(handler: { _, _ in "OK" }),
                                     maxPairsPerNight: 50, graph: g)
        let cands = [mem("c1", "SwiftUI 5 加了 NavigationStack")]
        let exist = [mem("e1", "SwiftUI 4 用 NavigationView")]
        let dur = exist
        _ = try await d.link(candidates: cands, against: dur)
        XCTAssertEqual(d.lastLLMCalls, 1, "1 对共享 token → 1 LLM 调用")
        XCTAssertEqual(d.lastPrescreenResult?.toCompare.count, 1)
    }

    func testContradictionDetector_skipsUnrelated_zeroLLMCalls() async throws {
        // 0 共享 → 0 LLM
        let g = KnowledgeGraph()
        var d = ContradictionDetector(llm: MockLLMProvider(handler: { _, _ in "OK" }),
                                     maxPairsPerNight: 50, graph: g)
        let cands = [mem("c1", "在 SwiftUI 里用 NavigationStack")]
        let exist = [mem("e1", "PostgreSQL 用 pg_dump 备份")]
        _ = try await d.link(candidates: cands, against: exist)
        XCTAssertEqual(d.lastLLMCalls, 0, "0 相关 → 0 LLM 调用 (spec 验收)")
    }
}
