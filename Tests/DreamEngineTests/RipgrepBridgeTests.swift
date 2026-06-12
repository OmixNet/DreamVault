// P2-6: RipgrepBridge 单测
import XCTest
@testable import DreamEngine
import Foundation

final class RipgrepBridgeTests: XCTestCase {
    // MARK: - parseOutput

    func testParseSingleHit() {
        let out = "raw/notes.md:5:hello world"
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].file, "raw/notes.md")
        XCTAssertEqual(hits[0].line, 5)
        XCTAssertEqual(hits[0].text, "hello world")
    }

    func testParseMultipleHits() {
        let out = """
        a.md:1:foo
        b.md:2:bar
        c.md:3:baz
        """
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].file, "a.md")
        XCTAssertEqual(hits[2].text, "baz")
    }

    func testParseTextWithColons() {
        // text 内含 : (e.g. "08:30 起床"), 限 2 次 split 应保留完整
        let out = "raw/today.md:10:08:30 起床了 09:00 吃早饭"
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].line, 10)
        XCTAssertEqual(hits[0].text, "08:30 起床了 09:00 吃早饭")
    }

    func testParseEmptyOutput() {
        let hits = RipgrepBridge.parseOutput("", root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertTrue(hits.isEmpty)
    }

    func testParseEmptyLinesSkipped() {
        let out = "a.md:1:foo\n\n\nb.md:2:bar\n"
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits.count, 2)
    }

    func testParseInvalidLineSkipped() {
        // "a.md:abc:bad" 中间不是数字 → 跳过
        let out = """
        a.md:1:good
        a.md:abc:bad
        b.md:3:also good
        """
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].text, "good")
        XCTAssertEqual(hits[1].text, "also good")
    }

    func testParseStripsAbsolutePrefix() {
        // fileRaw 是绝对路径
        let out = "/tmp/vault/raw/notes.md:5:hello"
        let hits = RipgrepBridge.parseOutput(out, root: URL(fileURLWithPath: "/tmp/vault"))
        XCTAssertEqual(hits[0].file, "raw/notes.md")  // 切到相对
    }

    func testParseLimitsMaxResults() {
        let lines = (1...300).map { "f\($0).md:1:line \($0)" }.joined(separator: "\n")
        let hits = RipgrepBridge.parseOutput(lines, root: URL(fileURLWithPath: "/tmp/vault"), maxResults: 50)
        XCTAssertEqual(hits.count, 50)
    }

    // MARK: - locateRipgrep

    func testLocateRipgrepFindsSystemRG() {
        // 测试环境应装了 rg (在 /opt/homebrew/bin/rg)
        let path = RipgrepBridge.locateRipgrep()
        if let p = path {
            XCTAssertTrue(p.contains("rg"), "应找到 rg 路径: \(p)")
        }
        // 没装也 OK — ripgrep 是 optional, fallback mdfind
    }

    // MARK: - end-to-end search (real rg if available)

    func testRealSearch() async throws {
        // 创建临时 vault, 写测试文件
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p2-6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "first line\nsecond UNIQUE_TOKEN line\nthird".write(
            to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "no match here".write(
            to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        // ripgrep 不可用就 skip
        guard RipgrepBridge.locateRipgrep() != nil else {
            throw XCTSkip("ripgrep not installed, skip integration test")
        }
        guard let hits = RipgrepBridge.search(query: "UNIQUE_TOKEN", root: dir) else {
            XCTFail("rg 应返回 hits")
            return
        }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].file, "a.md")
        XCTAssertEqual(hits[0].line, 2)
    }
}
