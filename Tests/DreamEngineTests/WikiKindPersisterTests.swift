import XCTest
@testable import DreamEngine

/// 覆盖架构文档第 1/3.4/4 节落地的三块：
///   1. MemoryKind 字段（kind/relatedTo）的默认/解码/分发
///   2. Persister 按 kind 把 wiki 页写到 entities/concepts/syntheses/
///   3. 矛盾建链 → wiki 页 ## contradicts 双向渲染 + relatedTo 同步
///   4. Decayer 公式边界
///   5. 归档：移到 wiki/archive/ 并从原 kind 目录删页
final class WikiKindPersisterTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dreamvault-wiki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempDir = tmp
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    // MARK: - 1. MemoryKind 默认值兼容

    func testMemoryKind_defaultValueIsConcept() {
        // 新构造的 Memory 不指定 kind → .concept（向后兼容老 ledger）
        let m = Memory(text: "t", sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")])
        XCTAssertEqual(m.kind, .concept)
    }

    func testMemoryKind_decodesMissingFieldAsConcept() throws {
        // 老 ledger JSON 没有 kind 字段 → 解码应得 .concept（不抛错）
        let old = """
        {
          "id": "old-id",
          "text": "legacy",
          "sources": [{"file":"raw/a.md","line":1,"excerpt":"x"}],
          "status": "durable",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastAccess": "2026-01-01T00:00:00Z",
          "reinforceCount": 0,
          "inboundLinks": 0,
          "contradicts": []
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(Memory.self, from: Data(old.utf8))
        XCTAssertEqual(m.kind, .concept)
        XCTAssertEqual(m.relatedTo, [])
    }

    func testMemoryKind_decodesEntityFromNewLedger() throws {
        // 新 ledger 含 kind:"entity" → 解码应得 .entity
        let new = """
        {
          "id": "new-id",
          "text": "工具",
          "sources": [{"file":"raw/a.md","line":1,"excerpt":"x"}],
          "status": "durable",
          "createdAt": "2026-01-01T00:00:00Z",
          "lastAccess": "2026-01-01T00:00:00Z",
          "reinforceCount": 0,
          "inboundLinks": 0,
          "contradicts": [],
          "kind": "entity",
          "relatedTo": ["other"]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let m = try dec.decode(Memory.self, from: Data(new.utf8))
        XCTAssertEqual(m.kind, .entity)
        XCTAssertEqual(m.relatedTo, ["other"])
    }

    // MARK: - 2. Persister 按 kind 落不同目录

    private func durable(_ id: String, kind: MemoryKind,
                         lastAccess: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Memory {
        Memory(id: id, text: "lesson \(id)",
               sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
               status: .durable, lastAccess: lastAccess, kind: kind)
    }

    func testPersister_wikiRelPath_dispatchesByKind() {
        let e = durable("e1", kind: .entity)
        let c = durable("c1", kind: .concept)
        let s = durable("s1", kind: .synthesis)
        XCTAssertEqual(Persister.wikiRelPath(for: e), "wiki/entities/e1.md")
        XCTAssertEqual(Persister.wikiRelPath(for: c), "wiki/concepts/c1.md")
        XCTAssertEqual(Persister.wikiRelPath(for: s), "wiki/syntheses/s1.md")
    }

    func testPersister_ensureWikiDirs_createsAllFourSubdirs() throws {
        let p = Persister(vaultRoot: tempDir)
        let input = Persister.Input(ledger: Ledger(), now: Date())
        _ = try p.persist(input)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/entities").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/concepts").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/syntheses").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/archive").path))
    }

    func testPersister_durablePagesWrittenToKindSubdirs() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let e = durable("e1", kind: .entity)
        let c = durable("c1", kind: .concept)
        let s = durable("s1", kind: .synthesis)
        let input = Persister.Input(ledger: Ledger(memories: [e, c, s]), now: now)
        let p = Persister(vaultRoot: tempDir)
        let outcome = try p.persist(input)

        XCTAssertTrue(outcome.wikiPagesWritten.contains("wiki/entities/e1.md"))
        XCTAssertTrue(outcome.wikiPagesWritten.contains("wiki/concepts/c1.md"))
        XCTAssertTrue(outcome.wikiPagesWritten.contains("wiki/syntheses/s1.md"))
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/entities/e1.md").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/concepts/c1.md").path))
        XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent("wiki/syntheses/s1.md").path))
    }

    func testPersister_wikiPage_frontmatterContainsKind() throws {
        // 落盘的 wiki 页 frontmatter 应含 kind: 字段（人读/grep 友好）
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let e = durable("entity-1", kind: .entity)
        let input = Persister.Input(ledger: Ledger(memories: [e]), now: now)
        let p = Persister(vaultRoot: tempDir)
        _ = try p.persist(input)
        let body = try String(contentsOf: tempDir.appendingPathComponent("wiki/entities/entity-1.md"),
                              encoding: .utf8)
        XCTAssertTrue(body.contains("kind: entity"), "frontmatter 应含 kind: entity")
    }

    // MARK: - 3. 矛盾链接落 wiki 页

    func testPersister_contradictionWikilinksAppearInBothPages() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var a = durable("a-entity", kind: .entity)
        a.contradicts = ["b-concept"]
        var b = durable("b-concept", kind: .concept)
        b.contradicts = ["a-entity"]
        let input = Persister.Input(ledger: Ledger(memories: [a, b]), now: now)
        let p = Persister(vaultRoot: tempDir)
        _ = try p.persist(input)

        let pageA = try String(contentsOf: tempDir.appendingPathComponent("wiki/entities/a-entity.md"),
                               encoding: .utf8)
        let pageB = try String(contentsOf: tempDir.appendingPathComponent("wiki/concepts/b-concept.md"),
                               encoding: .utf8)

        // 双向链接：kind-aware wikilink 写到对应子目录
        XCTAssertTrue(pageA.contains("[[wiki/concepts/b-concept]]"),
                      "a 页面应含指向 b 的概念子目录链接")
        XCTAssertTrue(pageB.contains("[[wiki/entities/a-entity]]"),
                      "b 页面应含指向 a 的实体子目录链接")
        XCTAssertTrue(pageA.contains("## contradicts"))
        XCTAssertTrue(pageB.contains("## contradicts"))
    }

    func testPersister_syncRelatedTo_bidirectionalFromContradicts() throws {
        // contradicts → relatedTo 双向补齐（架构文档第 4 节末段：relatedTo
        // 避免扫整盘 graph 算 related）
        var a = durable("a", kind: .concept)
        a.contradicts = ["b"]
        let b = durable("b", kind: .concept)
        // b 初始 relatedTo 为空
        XCTAssertTrue(b.relatedTo.isEmpty)

        let input = Persister.Input(ledger: Ledger(memories: [a, b]),
                                    now: Date(timeIntervalSince1970: 1_700_000_000))
        let p = Persister(vaultRoot: tempDir)
        let outcome = try p.persist(input)

        let aOut = outcome.ledger.memories.first(where: { $0.id == "a" })!
        let bOut = outcome.ledger.memories.first(where: { $0.id == "b" })!
        XCTAssertTrue(aOut.relatedTo.contains("b"), "a.relatedTo 应含 b")
        XCTAssertTrue(bOut.relatedTo.contains("a"), "b.relatedTo 应含 a（双向补齐）")
    }

    // MARK: - 4. Decayer 公式边界（架构第 4 节）

    func testDecayer_salienceBounds() {
        // w_r + w_f + w_l = 1 且 0 ≤ 各分量 ≤ 1 → salience 必 ∈ [0, 1]
        let d = Decayer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(daysAgo: Double, n: Int, links: Int)] = [
            (0, 100, 100),      // 全满
            (10_000, 0, 0),     // 全部为零
            (30, 5, 8),         // 边界：τ=30
            (1, 0, 0),
        ]
        for c in cases {
            let m = Memory(text: "t",
                           sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                           status: .durable,
                           lastAccess: now.addingTimeInterval(-c.daysAgo * 86_400),
                           reinforceCount: c.n, inboundLinks: c.links)
            let s = d.salience(of: m, now: now)
            XCTAssertGreaterThanOrEqual(s, 0, "salience 应 ≥ 0: \(c) → \(s)")
            XCTAssertLessThanOrEqual(s, 1, "salience 应 ≤ 1: \(c) → \(s)")
        }
    }

    func testDecayer_freshFullReinforceTopSalience() {
        // 刚访问 + 频繁强化 + 链接满 → salience 接近 1
        let d = Decayer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let m = Memory(text: "t",
                       sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                       status: .durable,
                       lastAccess: now,
                       reinforceCount: 100, inboundLinks: 100)
        let s = d.salience(of: m, now: now)
        XCTAssertGreaterThan(s, 0.95, "近访问+高强化+满链接 → salience ≈ 1: \(s)")
    }

    func testDecayer_staleAndLowSalienceTriggersArchive() {
        // 久未访问 + 低强化 + 无链接 → archive 决策
        let d = Decayer()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let m = Memory(text: "t",
                       sources: [SourceRef(file: "raw/a.md", line: 1, excerpt: "x")],
                       status: .durable,
                       lastAccess: now.addingTimeInterval(-365 * 86_400),
                       reinforceCount: 0, inboundLinks: 0)
        let r = d.evaluate(m, now: now)
        XCTAssertEqual(r.action, .archive)
        XCTAssertLessThan(r.salience, 0.15)
    }

    // MARK: - 5. 归档：移目录

    func testPersister_archivedMovesFromKindSubdirToArchive() throws {
        // 先把一条 durable 写到 wiki/concepts/，再模拟 Decayer 把它标 archive，
        // 验证：archive 页被创建 + concepts/ 旧页被删除
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let m = durable("old-1", kind: .concept)
        let p = Persister(vaultRoot: tempDir)
        // 1. 落 wiki/concepts/
        _ = try p.persist(Persister.Input(ledger: Ledger(memories: [m]), now: now))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/concepts/old-1.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/archive/old-1.md").path))

        // 2. Decayer 决定 archive
        let decayer = Decayer()
        let decay = decayer.evaluate(m, now: now.addingTimeInterval(200 * 86_400))
        XCTAssertEqual(decay.action, .archive)

        // 3. 再跑一次 persist：archive 决策 + delete old concepts page
        _ = try p.persist(Persister.Input(
            ledger: Ledger(memories: [m]),
            decayResults: [decay],
            now: now.addingTimeInterval(200 * 86_400)
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/archive/old-1.md").path),
                      "应写到 wiki/archive/old-1.md")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/concepts/old-1.md").path),
                     "原 wiki/concepts/old-1.md 应被删除")
    }

    func testPersister_archivedRemovesPageFromEntityOrSynthesisSubdir() throws {
        // 归档应能清掉任何 kind 子目录的旧页（不只 concepts/）
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entity = durable("ent-2", kind: .entity)
        let p = Persister(vaultRoot: tempDir)
        _ = try p.persist(Persister.Input(ledger: Ledger(memories: [entity]), now: now))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/entities/ent-2.md").path))

        let decayer = Decayer()
        let decay = decayer.evaluate(entity, now: now.addingTimeInterval(200 * 86_400))
        XCTAssertEqual(decay.action, .archive)

        _ = try p.persist(Persister.Input(
            ledger: Ledger(memories: [entity]),
            decayResults: [decay],
            now: now.addingTimeInterval(200 * 86_400)
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/archive/ent-2.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("wiki/entities/ent-2.md").path),
                     "原 wiki/entities/ent-2.md 应被删除")
    }
}
