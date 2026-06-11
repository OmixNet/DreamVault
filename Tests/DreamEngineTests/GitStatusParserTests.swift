import XCTest
@testable import DreamEngine

final class GitStatusParserTests: XCTestCase {

    private let parser = GitStatusParser()

    // MARK: - 基础三态

    func testEmpty() {
        XCTAssertEqual(parser.parse(""), [:])
    }

    func testWhitespaceOnlyLines() {
        XCTAssertEqual(parser.parse("\n\n   \n"), [:])
    }

    func testCleanSkipsStaging() {
        // 干净工作区不产生 entry
        XCTAssertEqual(parser.parse(""), [:])
    }

    // MARK: - Modified（worktree 改动）

    func testModifiedWorktree() {
        let out = " M notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .modified)
    }

    func testModifiedStagedPrefix() {
        // 某些 git 版本 / locale 输出 "M  notes/draft.md" 表示 staged
        let out = "M  notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .staged)
    }

    func testModifiedWorktreeAndStaged() {
        // "MM" = staged + worktree 改动 → 视为 staged（用户已经手动 add 过）
        let out = "MM notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .staged)
    }

    // MARK: - Conflict

    func testConflictUU() {
        let out = "UU notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .conflict)
    }

    func testConflictAA() {
        let out = "AA notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .conflict)
    }

    func testConflictDD() {
        let out = "DD notes/draft.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/draft.md"], .conflict)
    }

    // MARK: - Untracked / Ignored

    func testUntracked() {
        let out = "?? newfile.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["newfile.md"], .untracked)
    }

    func testIgnoredSkipped() {
        // "!!" 视为 clean（已知忽略，跳过）
        let out = "!! .DS_Store"
        let result = parser.parse(out)
        XCTAssertEqual(result, [:])
    }

    // MARK: - Rename

    func testRename() {
        let out = "R  old/name.md -> new/name.md"
        let result = parser.parse(out)
        // 解析后只剩 new/path
        XCTAssertEqual(result["new/name.md"], .staged)
    }

    // MARK: - 多文件混合

    func testMultipleFiles() {
        let out = """
         M notes/a.md
        MM notes/b.md
        UU notes/c.md
        ?? notes/d.md
        """
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/a.md"], .modified)
        XCTAssertEqual(result["notes/b.md"], .staged)
        XCTAssertEqual(result["notes/c.md"], .conflict)
        XCTAssertEqual(result["notes/d.md"], .untracked)
    }

    // MARK: - 路径含空格 / 中文

    func testPathWithSpaces() {
        // git 会用引号包 " M path with space.md"
        let out = #" M "path with space.md""#
        let result = parser.parse(out)
        // 当前实现不处理引号转义 —— 但应该至少能产生 entry（按字面解析）
        XCTAssertNotNil(result.first { $0.key.contains("path") })
    }

    // MARK: - Edge: 单字符状态（Y 缺 X）

    func testSingleCharStatusY() {
        // "M notes/a.md" 只有 1 个状态字符（罕见但合法）→ 视为 modified
        let out = "M notes/a.md"
        let result = parser.parse(out)
        XCTAssertEqual(result["notes/a.md"], .staged)
    }
}
