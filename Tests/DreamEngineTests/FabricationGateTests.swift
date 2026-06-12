// P0-3 tests: 假 excerpt 闸门 + 计数累加路径
// 重点: SourceRefValidator 直接单测 + Consolidator 3 步路径下 LLM 生成 fake excerpt 被拒收
import XCTest
@testable import DreamEngine

final class SourceRefValidatorTests: XCTestCase {
    // 1. excerpt 跟 file body 完全一致 → pass
    func testExactSubstringPasses() {
        let body = """
        # Title
        Some content about appKit here.
        Another line.
        """
        let ok = SourceRefValidator.validate(excerpt: "Some content about appKit here.", in: body)
        XCTAssertTrue(ok)
    }

    // 2. excerpt 是 body 的一部分（中间截取）
    func testContainedSubstringPasses() {
        let body = "first line\nsecond line about ML\nthird line\n"
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "second line about ML", in: body))
    }

    // 3. 空白归一化: body 多个连续空白, excerpt 单个 → pass
    func testWhitespaceNormalizedPasses() {
        let body = "key   insight:\nmultiple   spaces   collapsed"
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "key insight: multiple spaces collapsed", in: body))
    }

    // 4. CJK 跨行 normalize
    func testChineseNewlineNormalizedPasses() {
        let body = "第一行\n第二行关键内容\n第三行"
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "第一行 第二行关键内容 第三行", in: body))
    }

    // 5. excerpt 完全不在 body → reject
    func testFabricatedExcerptRejected() {
        let body = "原始内容: SwiftUI 写 UI"
        XCTAssertFalse(SourceRefValidator.validate(excerpt: "AppKit 写 UI 性能更好", in: body))
    }

    // 6. 短 excerpt (< 5) → pass (防误伤)
    func testShortExcerptAlwaysPasses() {
        let body = "alpha"
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "z", in: body))
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "ab", in: body))
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "abc", in: body))
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "abcd", in: body))
    }

    // 7. 空 excerpt → pass (向后兼容)
    func testEmptyExcerptPasses() {
        XCTAssertTrue(SourceRefValidator.validate(excerpt: "", in: "any body"))
    }

    // 8. file 不在 lookup → pass (边缘)
    func testMissingFileContentPasses() {
        let (passed, rejected) = SourceRefValidator.validateBatch(
            refs: [(relPath: "raw/ghost.md", excerpt: "anything")],
            fileContentLookup: [:]
        )
        XCTAssertEqual(passed.count, 1)
        XCTAssertEqual(rejected.count, 0)
    }

    // 9. validateBatch 混合: 1 通过 1 拒收
    func testValidateBatchMixed() {
        let lookup = ["raw/real.md": "actual content is here",
                      "raw/fake.md": "actual content is here"]
        let (passed, rejected) = SourceRefValidator.validateBatch(
            refs: [
                (relPath: "raw/real.md", excerpt: "actual content"),  // substring ✓
                (relPath: "raw/fake.md", excerpt: "completely made up")
            ],
            fileContentLookup: lookup
        )
        XCTAssertEqual(passed.count, 1)
        XCTAssertEqual(rejected.count, 1)
    }
}

// P0-3 集成测试: 3 步路径下, LLM 生成的 draft.sourceExcerpt 跟 raw file 不匹配 → rejectedFabricatedCount 增
final class FabricationGateIntegrationTests: XCTestCase {
    func src(_ f: String, excerpt: String) -> SourceRef {
        SourceRef(file: f, line: 1, excerpt: excerpt)
    }

    /// Mock LLM: 3 步走 analyze → generate → verify
    /// 按 callCount 区分 phase. analyze 假装分析完毕, generate 返回 draft JSON (含 sourceExcerpt),
    /// verify 接受 YES (否则 3 步路径直接走 fail 不测到 gate)
    final class FabricatedDraftLLM: LLMProvider {
        let fakeExcerpt: String
        var callCount = 0
        init(fakeExcerpt: String) { self.fakeExcerpt = fakeExcerpt }
        func complete(system: String, user: String) async throws -> String {
            callCount += 1
            switch callCount {
            case 1:
                // analyze
                return #"{"category":"observation","key":"fake-key"}"#
            case 2:
                // generate: 关键: 故意让 LLM 返回的 excerpt 跟 raw file 内容不匹配
                // 必须是 array
                let json = "[{\"text\":\"结论性陈述\",\"sourceFile\":\"raw/a.md\",\"sourceExcerpt\":\"" + fakeExcerpt + "\",\"sourceLine\":1,\"decayClassRaw\":\"normal\",\"kind\":\"concept\"}]"
                return json
            default:
                // verify (3 步也有这一步, 跟 2 步同)
                return "YES"
            }
        }
    }

    func testRejectsFabricatedExcerptIn3Step() async throws {
        // 准备 raw file 内容
        let realBody = "SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定"
        let fakeExcerpt = "AppKit 性能更好"  // 不在 realBody 里
        let llm = FabricatedDraftLLM(fakeExcerpt: fakeExcerpt)
        let c = Consolidator(
            llm: llm,
            config: ConsolidationConfig(useThreeStepCoT: true, concurrency: 1),
            sourceContents: ["raw/a.md": realBody]
        )
        let candidate = Memory(
            text: "raw 里说 SwiftUI 稳定",
            sources: [src("raw/a.md", excerpt: "SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定")],
            decayClass: .normal,
            kind: .concept
        )
        var rejected = 0
        let out = try await c.consolidate3Step([candidate], rejectedFabricated: &rejected)
        XCTAssertEqual(rejected, 1, "fabricated excerpt 应被闸门拒收")
        XCTAssertTrue(out.isEmpty, "被拒的 candidate 不进 out")
    }

    func testAcceptsGenuineExcerptIn3Step() async throws {
        // excerpt 跟 raw body substring → pass
        let realBody = "SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定"
        let llm = FabricatedDraftLLM(fakeExcerpt: "SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定")
        let c = Consolidator(
            llm: llm,
            config: ConsolidationConfig(useThreeStepCoT: true, concurrency: 1),
            sourceContents: ["raw/a.md": realBody]
        )
        let candidate = Memory(
            text: "raw 里说 SwiftUI 稳定",
            sources: [src("raw/a.md", excerpt: "SwiftUI 用于 macOS 13+ 的桌面 UI 非常稳定")],
            decayClass: .normal,
            kind: .concept
        )
        var rejected = 0
        let out = try await c.consolidate3Step([candidate], rejectedFabricated: &rejected)
        XCTAssertEqual(rejected, 0, "genuine excerpt 不应被拒收")
        // 3 步路径下应该 generate 一次拿 draft, verify 一次拿 YES → accepted
        XCTAssertFalse(out.isEmpty, "genuine excerpt 应被接受")
    }

    func testFabricationGate2StepPath() async throws {
        // 2 步路径下, candidate 自带 excerpt = raw 内容, sourceContents lookup 一致 → pass
        let realBody = "Memory 类有 status 字段"
        // 2 步路径: 一次 LLM = verify. mock 直接返回 YES
        final class YesLLM: LLMProvider {
            func complete(system: String, user: String) async throws -> String { "YES" }
        }
        let llm = YesLLM()
        let c = Consolidator(
            llm: llm,
            config: ConsolidationConfig(useThreeStepCoT: false, concurrency: 1),
            sourceContents: ["raw/a.md": realBody]
        )
        let candidate = Memory(
            text: "Memory 类有 status 字段",
            sources: [src("raw/a.md", excerpt: "Memory 类有 status 字段")],
            decayClass: .normal,
            kind: .concept
        )
        var rejected = 0
        let out = try await c.consolidate([candidate], rejectedFabricated: &rejected)
        XCTAssertEqual(rejected, 0, "2 步路径下 candidate 自带真实 excerpt 不应被拒")
        // 2 步 verify "YES" → 进 out
        XCTAssertFalse(out.isEmpty)
    }
}

// DEBUG
// (removed probe test)
