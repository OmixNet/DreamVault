import XCTest
@testable import DreamEngine

final class DiffGeneratorTests: XCTestCase {

    private let diff = DiffGenerator()

    // MARK: - 基础

    func testIdenticalIsEmpty() {
        let r = diff.diff(old: "a\nb\nc", new: "a\nb\nc")
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.addedCount, 0)
        XCTAssertEqual(r.removedCount, 0)
    }

    func testSingleLineAdd() {
        let r = diff.diff(old: "a\nb", new: "a\nb\nc")
        XCTAssertEqual(r.addedCount, 1)
        XCTAssertEqual(r.removedCount, 0)
        XCTAssertEqual(r.lines.last?.kind, .added)
        XCTAssertEqual(r.lines.last?.text, "c")
    }

    func testSingleLineRemove() {
        let r = diff.diff(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(r.addedCount, 0)
        XCTAssertEqual(r.removedCount, 1)
        XCTAssertTrue(r.lines.contains { $0.kind == .removed && $0.text == "b" })
    }

    // MARK: - 多行

    func testReplaceBlock() {
        let r = diff.diff(old: """
        line1
        line2-old
        line3
        """, new: """
        line1
        line2-new
        line3
        """)
        XCTAssertEqual(r.addedCount, 1)
        XCTAssertEqual(r.removedCount, 1)
        XCTAssertTrue(r.lines.contains { $0.kind == .removed && $0.text == "line2-old" })
        XCTAssertTrue(r.lines.contains { $0.kind == .added && $0.text == "line2-new" })
    }

    // MARK: - Edge

    func testEmptyOld() {
        let r = diff.diff(old: "", new: "a\nb")
        XCTAssertEqual(r.addedCount, 2)
        XCTAssertEqual(r.removedCount, 0)
    }

    func testEmptyNew() {
        let r = diff.diff(old: "a\nb", new: "")
        XCTAssertEqual(r.addedCount, 0)
        XCTAssertEqual(r.removedCount, 2)
    }

    func testBothEmpty() {
        let r = diff.diff(old: "", new: "")
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - 顺序保持

    func testLineOrderPreserved() {
        let r = diff.diff(old: "z", new: "a")
        // 1 删除 + 1 添加，按 diff 算法回溯顺序 = 先删后加
        XCTAssertEqual(r.lines.first?.kind, .removed)
        XCTAssertEqual(r.lines.first?.text, "z")
        XCTAssertEqual(r.lines.last?.kind, .added)
        XCTAssertEqual(r.lines.last?.text, "a")
    }
}
