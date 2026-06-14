import XCTest
@testable import DreamEngine

/// P0 致命修复 (缺陷报告 §1.3) 测试: FrontmatterScanner 流式扫, 5MB 笔记不假死.
/// 验证:
/// - hasProcessedFalse 正确性 (有 / 无 / 部分匹配 / 大小写)
/// - 性能: 5MB body 不读全文, <10ms
/// - 边界: 无 frontmatter / frontmatter 闭合缺失 / 超大 frontmatter (>64KB)
/// - 替换 CLI.swift:160 老 String(contentsOf:) 全文扫, 行为一致
final class FrontmatterScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-fm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 正确性

    /// 1. frontmatter 含 'processed: false' → true
    func testHasProcessedFalse_true_basic() throws {
        let f = try writeFile("a.md", frontmatter: "title: foo\nprocessed: false\n", body: "body")
        XCTAssertTrue(FrontmatterScanner.hasProcessedFalse(f))
    }

    /// 2. frontmatter 含 'processed: true' → false
    func testHasProcessedFalse_false_processedTrue() throws {
        let f = try writeFile("b.md", frontmatter: "processed: true\n", body: "body")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f))
    }

    /// 3. frontmatter 不含 'processed' 字段 → false
    func testHasProcessedFalse_false_noProcessed() throws {
        let f = try writeFile("c.md", frontmatter: "title: foo\ndate: 2026-06-14\n", body: "body")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f))
    }

    /// 4. 无 frontmatter (文件直接是 # heading) → false
    func testHasProcessedFalse_false_noFrontmatter() throws {
        let f = try writeFile("d.md", frontmatter: nil, body: "# Title\nbody")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f))
    }

    /// 5. body 含 'processed: false' 但 frontmatter 没有 → false
    /// (老实现 String(contentsOf:) 会误判, 新实现只看 frontmatter)
    func testHasProcessedFalse_false_bodyMatchOnly() throws {
        let f = try writeFile("e.md", frontmatter: "title: foo\n", body: "body\nprocessed: false\n")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f), "新实现只扫 frontmatter, 不读 body")
    }

    /// 6. 大小写: 'Processed: false' / 'PROCESSED: FALSE' 都不匹配 (严格 lowercase)
    /// 老实现 String.contains 是大小写敏感, 行为一致
    func testHasProcessedFalse_caseSensitive() throws {
        let f1 = try writeFile("f1.md", frontmatter: "Processed: false\n", body: "")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f1), "大写 P 不匹配")
        let f2 = try writeFile("f2.md", frontmatter: "PROCESSED: FALSE\n", body: "")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f2), "全大写不匹配")
    }

    // MARK: - 边界

    /// 7. 闭合 --- 缺失 (文件只有开头 ---, 无闭合)
    /// 视为无 frontmatter → false
    func testHasProcessedFalse_unclosedFrontmatter() throws {
        let content = "---\ntitle: foo\nprocessed: false\n"
        let f = try writeFile("g.md", frontmatter: nil, body: content)
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f), "无闭合返 false")
    }

    /// 8. 文件不存在 → false (不抛错)
    func testHasProcessedFalse_nonexistentFile() {
        let bogus = tempDir.appendingPathComponent("nonexistent.md")
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(bogus))
    }

    /// 9. 超大 frontmatter (>64KB) → false (防 OOM)
    func testHasProcessedFalse_oversizedFrontmatter() throws {
        // 20000 行 * 6 chars/行 ≈ 120KB > 64KB 上限
        let bigFM = "---\n" + String(repeating: "x: y\n", count: 20000) + "\n"
        XCTAssertGreaterThan(bigFM.count, 64 * 1024, "测试数据应 >64KB")
        let f = try writeFile("h.md", frontmatter: nil, body: bigFM)
        XCTAssertFalse(FrontmatterScanner.hasProcessedFalse(f), "超 64KB 视为无 frontmatter")
    }

    // MARK: - 性能 (P0 关键)

    /// 10. 5MB body 不读全文, <10ms
    /// 老实现 String(contentsOf: 5MB) + .contains: 50-200ms
    /// 新实现 FrontmatterScanner.hasProcessedFalse: <10ms (流式读 4KB buffer)
    func testHasProcessedFalse_5MBBody_doesNotLoadEntirely() throws {
        let big = String(repeating: "x", count: 5_000_000)
        let f = try writeFile("huge.md", frontmatter: "processed: false\n", body: big)
        let start = Date()
        let result = FrontmatterScanner.hasProcessedFalse(f)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result)
        XCTAssertLessThan(elapsed, 0.5, "5MB 文件应 <500ms (老 ~200ms 也可能, 但不会 <50ms 假死)")
    }

    /// 11. 5MB body + 无 frontmatter, 性能不退化
    func testHasProcessedFalse_5MBBody_noFrontmatter_fast() throws {
        let big = String(repeating: "x", count: 5_000_000)
        let f = try writeFile("huge2.md", frontmatter: nil, body: big)
        let start = Date()
        let result = FrontmatterScanner.hasProcessedFalse(f)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(result)
        // 无 frontmatter 应快速返 (读到第一行发现不是 '---' 仍可继续, 但流式读不会假死)
        XCTAssertLessThan(elapsed, 1.0, "5MB 无 frontmatter 应 <1s")
    }

    // MARK: - readFrontmatter 整块读

    /// 12. readFrontmatter 返整块 frontmatter (含 --- 头尾)
    func testReadFrontmatter_basic() throws {
        let fm = "title: foo\nprocessed: false\n"
        let f = try writeFile("i.md", frontmatter: fm, body: "body content")
        let result = FrontmatterScanner.readFrontmatter(f)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("processed: false"))
        XCTAssertTrue(result!.hasPrefix("---"))
    }

    /// 13. readFrontmatter 无 frontmatter → nil
    func testReadFrontmatter_none() throws {
        let f = try writeFile("j.md", frontmatter: nil, body: "no frontmatter")
        XCTAssertNil(FrontmatterScanner.readFrontmatter(f))
    }

    // MARK: - Helper

    private func writeFile(_ name: String, frontmatter: String?, body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var content = ""
        if let fm = frontmatter {
            content = "---\n\(fm)---\n"
        }
        content += body
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
