import XCTest
@testable import DreamEngine

/// P8: UserDirtyStrategy + GitRunner.autoCommitUserChanges
final class UserDirtyStrategyTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDirtyStrategy.userDefaultsKey)
        super.tearDown()
    }

    func testLoad_returnsNilWhenNotSet() {
        UserDefaults.standard.removeObject(forKey: UserDirtyStrategy.userDefaultsKey)
        XCTAssertNil(UserDirtyStrategy.load())
    }

    func testSave_thenLoad_roundTrip() {
        for s in UserDirtyStrategy.allCases {
            UserDirtyStrategy.save(s)
            XCTAssertEqual(UserDirtyStrategy.load(), s, "round-trip \(s.rawValue)")
        }
    }

    func testLoad_returnsNilForUnknownString() {
        UserDefaults.standard.set("nonsense", forKey: UserDirtyStrategy.userDefaultsKey)
        XCTAssertNil(UserDirtyStrategy.load(), "未知字符串 → nil 走 alert")
    }

    func testDisplayName_isHumanReadable() {
        XCTAssertTrue(UserDirtyStrategy.autoCommit.displayName.contains("Auto"))
        XCTAssertTrue(UserDirtyStrategy.prompt.displayName.contains("prompt"))
        XCTAssertTrue(UserDirtyStrategy.skip.displayName.contains("manually") ||
                      UserDirtyStrategy.skip.displayName.contains("touch"))
    }
}

/// P8: GitRunner.autoCommitUserChanges 测试
final class GitRunnerAutoCommitTests: XCTestCase {

    private func makeTmpVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p8-autocommit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q", "-b", "main", dir.path]
        try? p.run(); p.waitUntilExit()
        // config + 第一次 empty commit
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p2.currentDirectoryURL = dir
        p2.arguments = ["commit", "--allow-empty", "-q", "-m", "init"]
        try? p2.run(); p2.waitUntilExit()
        // 必须设 user.email/name 否则 commit 失败
        let p3 = Process()
        p3.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p3.currentDirectoryURL = dir
        p3.arguments = ["config", "user.email", "test@dreamvault.local"]
        try? p3.run(); p3.waitUntilExit()
        let p4 = Process()
        p4.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p4.currentDirectoryURL = dir
        p4.arguments = ["config", "user.name", "Test"]
        try? p4.run(); p4.waitUntilExit()
        return dir
    }

    func testAutoCommit_returnsNilWhenNoDirtyFiles() throws {
        let vault = makeTmpVault()
        let git = GitRunner(repoRoot: vault)
        let result = try git.autoCommitUserChanges()
        XCTAssertNil(result, "没有 dirty 文件 → nil")
    }

    func testAutoCommit_returnsHashWhenRawFileAdded() throws {
        let vault = makeTmpVault()
        // 写一个 raw/ 文件
        let rawDir = vault.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try "user wrote this in vault".write(
            to: rawDir.appendingPathComponent("note1.md"),
            atomically: true, encoding: .utf8)

        let git = GitRunner(repoRoot: vault)
        let hash = try git.autoCommitUserChanges()
        XCTAssertNotNil(hash, "有 raw/ dirty → 应该 commit")
        XCTAssertEqual(hash?.count, 40, "hash 长度 = 40 (sha1)")

        // 之后再调 → nil（已 commit 干净）
        let second = try git.autoCommitUserChanges()
        XCTAssertNil(second, "第二次调用应该没东西可 commit")
    }

    func testAutoCommit_skipsEnginePaths() throws {
        let vault = makeTmpVault()
        // 写一个引擎路径 .dream/test.json（不应该被 auto-commit）
        let dreamDir = vault.appendingPathComponent(".dream", isDirectory: true)
        try FileManager.default.createDirectory(at: dreamDir, withIntermediateDirectories: true)
        try "{\"key\":1}".write(
            to: dreamDir.appendingPathComponent("test.json"),
            atomically: true, encoding: .utf8)

        let git = GitRunner(repoRoot: vault)
        let hash = try git.autoCommitUserChanges()
        XCTAssertNil(hash, "只有 .dream/ dirty → 不该 commit（引擎路径跳过）")
    }
}
