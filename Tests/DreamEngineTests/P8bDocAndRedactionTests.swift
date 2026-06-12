import XCTest
@testable import DreamEngine

/// P8: 文档与代码一致性 + dream-report 加 redaction stats
final class P8bDocAndRedactionTests: XCTestCase {

    // MARK: - #1 DreamConfig.productionDefault 注释与默认值一致

    func testProductionDefault_actuallyMatchesDocs() {
        // P3 决策 T6：默认值 = 2 步 + 2 路（不是注释里"3 段 + 4 路"那个）
        // P8 修注释让两者对齐
        let cfg = DreamConfig.productionDefault.consolidation
        XCTAssertFalse(cfg.useThreeStepCoT,
                       "productionDefault 应是 2 步（useThreeStepCoT=false）")
        XCTAssertEqual(cfg.concurrency, 2,
                       "productionDefault 应是 concurrency=2")
    }

    func testFastDebug_actuallyMatchesDocs() {
        let cfg = DreamConfig.fastDebug.consolidation
        XCTAssertFalse(cfg.useThreeStepCoT)
        XCTAssertEqual(cfg.concurrency, 1)
    }

    // MARK: - #3 Gatherer.GatherResult 携带 redactionCounts

    private func makeTmpVaultWithRaw(_ rawContent: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p8b-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawDir = dir.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try rawContent.write(
            to: rawDir.appendingPathComponent("note.md"),
            atomically: true, encoding: .utf8)
        return dir
    }

    func testGatherer_returnsRedactionCounts() throws {
        // 写一段含 EMAIL + IP 的 raw，看 Gatherer.redactionCounts 是否累积
        let raw = """
        ---
        title: 测试笔记
        ---

        联系方式 user@example.com，电话 13812345678，服务器 IP 192.168.1.1。
        """
        let vault = try makeTmpVaultWithRaw(raw)
        let g = Gatherer(vaultRoot: vault)
        let result = try g.gather()
        XCTAssertFalse(result.candidates.isEmpty, "应该 gather 到 1 个候选")
        XCTAssertGreaterThan(result.redactionCounts.count, 0,
                             "应该至少有 1 类脱敏命中")
        // 至少应该命中 EMAIL
        XCTAssertNotNil(result.redactionCounts["EMAIL"], "EMAIL 应该被命中")
    }

    func testGatherer_zeroHitsWhenNoSensitiveData() throws {
        let raw = """
        ---
        title: 干净笔记
        ---

        纯中文内容，没有任何邮箱/手机/IP。
        """
        let vault = try makeTmpVaultWithRaw(raw)
        let g = Gatherer(vaultRoot: vault)
        let result = try g.gather()
        XCTAssertTrue(result.redactionCounts.isEmpty,
                      "无敏感字段时 redactionCounts 应为空；实际: \(result.redactionCounts)")
    }

    // MARK: - #3 Persister.report 包含 redaction 段

    func testPersisterReport_containsRedactionSection() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p8b-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let persister = Persister(vaultRoot: vault)
        let input = Persister.Input(
            ledger: Ledger(),
            newlyAccepted: [],
            gatheredFiles: ["raw/note1.md"],
            redactionCounts: ["EMAIL": 3, "IP_ADDR": 1]
        )
        let report = persister.report(
            input: input,
            archivedIDs: [],
            needsReviewIDs: [],
            durableCount: 0
        )
        XCTAssertTrue(report.contains("## Redaction"),
                      "dream-report 应有 Redaction 段")
        XCTAssertTrue(report.contains("[REDACTED_EMAIL]: 3 处"))
        XCTAssertTrue(report.contains("[REDACTED_IP_ADDR]: 1 处"))
        XCTAssertTrue(report.contains("本轮共 4 处脱敏命中"))
    }

    func testPersisterReport_showsNoHitsWhenEmpty() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p8b-report2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let persister = Persister(vaultRoot: vault)
        let input = Persister.Input(
            ledger: Ledger(),
            newlyAccepted: [],
            gatheredFiles: ["raw/note1.md"],
            redactionCounts: [:]
        )
        let report = persister.report(
            input: input,
            archivedIDs: [],
            needsReviewIDs: [],
            durableCount: 0
        )
        XCTAssertTrue(report.contains("## Redaction"))
        XCTAssertTrue(report.contains("本轮无脱敏命中"),
                      "空 counts 应显示\"无脱敏命中\"")
    }

    // MARK: - #4 NightlyDreamScheduler 注释确认（grep 不到 stub 字样）

    /// 文档化保证：不再出现"stub / TODO"等自贬描述
    /// 这是 P3 时期写的"占位文本"已删除
    /// 如果有人改回，会失败。
    func testNightlyDreamScheduler_docIsNoLongerStub() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DreamEngineTests dir
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
            .appendingPathComponent("Sources/DreamEngine/NightlyDreamScheduler.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("先 stub"),
                       "NightlyDreamScheduler 不应再自称 stub")
        XCTAssertFalse(source.contains("真注册留给 T9 follow-up"),
                       "P3 时期的 follow-up 提示应删")
        XCTAssertTrue(source.contains("P8 修正"),
                      "应有 P8 文档修正标记")
        XCTAssertTrue(source.contains("用户级 LaunchAgent"),
                      "应明确说明用用户级 LaunchAgent")
    }
}
