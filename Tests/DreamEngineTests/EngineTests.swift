import XCTest
@testable import DreamEngine

final class DecayerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000_000)

    func mem(daysAgo: Double, reinforce: Int = 0, links: Int = 0,
             status: MemoryStatus = .durable, contradicts: [String] = []) -> Memory {
        Memory(text: "t",
               sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
               status: status,
               lastAccess: now.addingTimeInterval(-daysAgo * 86_400),
               reinforceCount: reinforce, inboundLinks: links,
               contradicts: contradicts)
    }

    func testRecentHighFrequencyIsSalient() {
        let d = Decayer()
        let s = d.salience(of: mem(daysAgo: 1, reinforce: 10, links: 8), now: now)
        XCTAssertGreaterThan(s, 0.7)
    }

    func testOldUnusedDecaysLow() {
        let d = Decayer()
        let s = d.salience(of: mem(daysAgo: 200, reinforce: 0, links: 0), now: now)
        XCTAssertLessThan(s, 0.15)
    }

    func testFrequencyMonotonic() {
        let d = Decayer()
        let low = d.salience(of: mem(daysAgo: 10, reinforce: 1), now: now)
        let high = d.salience(of: mem(daysAgo: 10, reinforce: 10), now: now)
        XCTAssertGreaterThan(high, low)
    }

    func testStaleLowSalienceGetsArchivedNotDeleted() {
        let d = Decayer()
        let r = d.evaluate(mem(daysAgo: 200, reinforce: 0, links: 0), now: now)
        XCTAssertEqual(r.action, .archive)  // archive，绝非物理删除
    }

    func testContradictionAlwaysGoesToReview() {
        let d = Decayer()
        // 即便分数很高，有矛盾就必须人工裁决
        let r = d.evaluate(mem(daysAgo: 1, reinforce: 10, links: 8,
                               contradicts: ["other-id"]), now: now)
        XCTAssertEqual(r.action, .needsReview)
    }

    func testArchivedNeverReArchived() {
        let d = Decayer()
        let r = d.evaluate(mem(daysAgo: 300, status: .archived), now: now)
        XCTAssertEqual(r.action, .keep)
    }
}

// 受控的假 LLM，用来测整合三闸
struct MockLLM: LLMProvider {
    let verdict: String
    func complete(system: String, user: String) async throws -> String { verdict }
}

final class ConsolidatorTests: XCTestCase {
    func src(_ f: String) -> SourceRef { SourceRef(file: f, line: 1, excerpt: "e") }

    func testGate1_DropsMemoryWithoutSource() async throws {
        let c = Consolidator(llm: MockLLM(verdict: "YES"))
        let noSrc = Memory(text: "无依据", sources: [])
        let out = try await c.consolidate([noSrc])
        XCTAssertTrue(out.isEmpty)  // 无来源 → 丢弃
    }

    func testGate3_DropsHallucinationWhenVerifyFails() async throws {
        let c = Consolidator(llm: MockLLM(verdict: "NO"))
        let m = Memory(text: "幻觉结论", sources: [src("raw/a.md")])
        let out = try await c.consolidate([m])
        XCTAssertTrue(out.isEmpty)  // 回读校验 NO → 丢弃
    }

    func testGate2_SingleSourceStaysCandidate() async throws {
        let c = Consolidator(llm: MockLLM(verdict: "YES"))
        let m = Memory(text: "单源观察", sources: [src("raw/a.md")])
        let out = try await c.consolidate([m])
        XCTAssertEqual(out.first?.status, .candidate)  // 单源不进 MEMORY.md
    }

    func testGate2_MultiSourceBecomesDurable() async throws {
        let c = Consolidator(llm: MockLLM(verdict: "YES"))
        let m = Memory(text: "多源规律",
                       sources: [src("raw/a.md"), src("raw/b.md")])
        let out = try await c.consolidate([m])
        XCTAssertEqual(out.first?.status, .durable)  // 两独立源 → 升 durable
    }
}

final class RedactorTests: XCTestCase {
    let r = Redactor()

    func testRedactsApiKey() {
        let out = r.redact("my key is sk-live-abc123XYZ4567890abcd ok").redactedText
        XCTAssertFalse(out.contains("sk-live-abc123XYZ4567890abcd"))
        XCTAssertTrue(out.contains("[REDACTED_API_KEY]"))
    }

    func testRedactsEmailAndCNPhone() {
        let rep = r.redact("联系 tim@example.com 或 13812345678")
        XCTAssertTrue(rep.redactedText.contains("[REDACTED_EMAIL]"))
        XCTAssertTrue(rep.redactedText.contains("[REDACTED_CN_PHONE]"))
        XCTAssertEqual(rep.counts["EMAIL"], 1)
        XCTAssertEqual(rep.counts["CN_PHONE"], 1)
    }

    func testRedactsCNIdCard() {
        let out = r.redact("身份证 110101199003078888 保密").redactedText
        XCTAssertTrue(out.contains("[REDACTED_CN_ID_CARD]"))
    }

    func testDoesNotOverRedactPlainText() {
        let rep = r.redact("用户倾向用 SwiftUI 而不是 AppKit")
        XCTAssertFalse(rep.redactedText.contains("[REDACTED"))
    }

    // MARK: - P3-T4: IP / 版本号 / OID 边界回归

    func testIpAddr_doesNotMatchFiveSegmentOid() {
        // 1.2.3.4.5 是 5 段 OID / 嵌套 IPv4，不该被截成 1.2.3.4
        let out = r.redact("snmp oid: 1.2.3.4.5 nested").redactedText
        XCTAssertTrue(out.contains("1.2.3.4.5"), "5 段 OID 不应被截: \(out)")
    }

    func testIpAddr_doesNotMatchOverflowSegment() {
        // 段值 >255 不是合法 IPv4
        let out = r.redact("ip 1.2.3.999 错误").redactedText
        XCTAssertTrue(out.contains("1.2.3.999"), "999 段值不应被截: \(out)")
    }

    func testIpAddr_doesNotMatchTooBig() {
        let out = r.redact("ip 256.1.1.1 错误").redactedText
        XCTAssertTrue(out.contains("256.1.1.1"), "256 段值不应被截: \(out)")
    }

    func testIpAddr_doesMatchLegitimateIp() {
        let out = r.redact("ping 192.168.1.1").redactedText
        XCTAssertTrue(out.contains("[REDACTED_IP_ADDR]"), "正常 IP 应被截: \(out)")
    }

    func testIpAddr_knownLimitVersionNumber() {
        // 已知限制：版本号 1.0.0.0 仍会被截（纯 4 段 0-255 数字 regex 无法区分 IP 和版本号）
        // 这个测试是"记录限制"而不是"fix it"——把限制写进测试，下次有人加 lookahead 会失败提醒
        let out = r.redact("release 1.0.0.0 ok").redactedText
        XCTAssertTrue(out.contains("[REDACTED_IP_ADDR]"),
                      "KNOWN LIMIT: 1.0.0.0 仍被误截。context-aware 修复需要更复杂的 lookahead，超出 regex。")
    }

    func testRedactsMemorySourcesToo() {
        let m = Memory(text: "见 tim@example.com",
                       sources: [SourceRef(file: "raw/a.md", line: 1,
                                           excerpt: "key sk-test-1234567890abcdef")])
        let red = r.redact(m)
        XCTAssertTrue(red.text.contains("[REDACTED_EMAIL]"))
        XCTAssertTrue(red.sources.first!.excerpt.contains("[REDACTED_API_KEY]"))
    }
}

// 按内容决定是否返回 CONFLICT 的 mock，用于矛盾检测测试
struct ConflictMockLLM: LLMProvider {
    let conflictWhenContains: String
    func complete(system: String, user: String) async throws -> String {
        user.contains(conflictWhenContains) ? "CONFLICT" : "OK"
    }
}

final class ContradictionDetectorTests: XCTestCase {
    func mem(_ id: String, _ text: String, status: MemoryStatus = .durable) -> Memory {
        Memory(id: id, text: text,
               sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "e")],
               status: status)
    }

    func testLinksContradictionBidirectionally() async throws {
        // 当 prompt 含 "AppKit" 时判为矛盾
        let d = ContradictionDetector(llm: ConflictMockLLM(conflictWhenContains: "AppKit"))
        let cand = [mem("c1", "应该用 AppKit")]
        let existing = [mem("e1", "一律用 SwiftUI")]
        let (c, e) = try await d.link(candidates: cand, against: existing)
        XCTAssertEqual(c.first?.contradicts, ["e1"])   // 双向建链
        XCTAssertEqual(e.first?.contradicts, ["c1"])
    }

    func testNoFalseContradiction() async throws {
        let d = ContradictionDetector(llm: ConflictMockLLM(conflictWhenContains: "ZZZ"))
        let cand = [mem("c1", "用 SwiftUI")]
        let existing = [mem("e1", "测试用 XCTest")]
        let (c, e) = try await d.link(candidates: cand, against: existing)
        XCTAssertTrue(c.first!.contradicts.isEmpty)    // 不相关 → 不建链
        XCTAssertTrue(e.first!.contradicts.isEmpty)
    }

    func testOnlyComparesAgainstDurable() async throws {
        // existing 是 candidate 而非 durable → 即便内容会触发 CONFLICT 也跳过
        let d = ContradictionDetector(llm: ConflictMockLLM(conflictWhenContains: "AppKit"))
        let cand = [mem("c1", "应该用 AppKit")]
        let existing = [mem("e1", "一律用 SwiftUI", status: .candidate)]
        let (c, _) = try await d.link(candidates: cand, against: existing)
        XCTAssertTrue(c.first!.contradicts.isEmpty)    // candidate 不参与比对
    }
}
