// P3-2: ContradictionDetector 解析 bug 修复 (评审 §2.4)
// 关键回归: "NO CONFLICT" 必须判 false (老代码 contains("CONFLICT") 判 true 错)
import XCTest
@testable import DreamEngine
import Foundation

final class ConflictParseTests: XCTestCase {
    // MARK: - 核心 bug 回归

    /// 评审 §2.4 关键 bug: 老代码 contains("CONFLICT") 把 "NO CONFLICT" 判 true
    func testNoConflictShouldReturnFalse() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("NO CONFLICT"))
    }

    func testNoConflictFullSentence() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("NO CONFLICT. A and B are consistent."))
    }

    // MARK: - 正向

    func testConflictUppercase() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("CONFLICT"))
    }

    func testConflictWithExplanation() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("CONFLICT. A says yes, B says no, opposite."))
    }

    func testYes() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("YES"))
    }

    func testTrueLowercase() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("true"))
    }

    // MARK: - 反向

    func testOk() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("OK"))
    }

    func testNo() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("NO"))
    }

    func testFalse() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("false"))
    }

    func testNone() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("NONE"))
    }

    func testNil() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("nil"))
    }

    // MARK: - 大小写不敏感

    func testCaseInsensitive() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("conflict"))
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer("Conflict"))
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("ok"))
    }

    // MARK: - JSON 格式

    func testJSONConflictTrue() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(#"{"conflict": true}"#))
    }

    func testJSONConflictFalse() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer(#"{"conflict": false}"#))
    }

    func testJSONConflictCapitalCase() {
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(#"{"CONFLICT": true}"#))
    }

    func testJSONInMarkdownFence() {
        // Swift raw string 不能含 """ — 改用普通 string
        let fenced = "```json\n{\"conflict\": true}\n```"
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(fenced))
    }

    func testJSONMalformedFallsBackToFirstWord() {
        // JSON 解析失败, 但首行 "CONFLICT" 命中首词
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(#"{conflict: true}"#))
    }

    // MARK: - 多行 / 复杂输出

    func testMultiLine() {
        let out = """
        I have analyzed both memories carefully.

        CONFLICT

        They express opposite views.
        """
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(out))
    }

    func testMultiLineNoConflict() {
        let out = """
        After analysis, I find them consistent.

        OK
        """
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer(out))
    }

    // MARK: - 边界

    func testEmpty() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer(""))
    }

    func testWhitespaceOnly() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("   \n\n  "))
    }

    func testMarkdownFenceConflict() {
        // 围栏包裹的 CONFLICT (无 JSON) — 改用普通 string
        let fenced = "```\nCONFLICT\n```"
        XCTAssertTrue(ContradictionDetector.parseConflictAnswer(fenced))
    }

    // MARK: - 否定词优先

    func testNegativeWordOverrides() {
        // 首 30 字符含 CONFLICT 但也有 NO, 应判 false
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("Not a CONFLICT, just similar"))
    }

    func testNoneOverrides() {
        XCTAssertFalse(ContradictionDetector.parseConflictAnswer("None of these conflict"))
    }
}
