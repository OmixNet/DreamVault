import XCTest
@testable import DreamEngine

/// P9: Rollback 二次确认 — GitRunner.lastCommitSummary 给 dialog 提供数据
final class RollbackConfirmationTests: XCTestCase {

    private func makeTmpVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p9-rb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q", "-b", "main", dir.path]
        try? p.run(); p.waitUntilExit()
        // 设 user（commit 需要）
        let configEmail = Process()
        configEmail.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configEmail.currentDirectoryURL = dir
        configEmail.arguments = ["config", "user.email", "test@dv.local"]
        try? configEmail.run(); configEmail.waitUntilExit()
        let configName = Process()
        configName.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configName.currentDirectoryURL = dir
        configName.arguments = ["config", "user.name", "Test"]
        try? configName.run(); configName.waitUntilExit()
        return dir
    }

    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testLastCommitSummary_parsesFieldsCorrectly() throws {
        let vault = makeTmpVault()
        // 写 3 个文件 + commit
        try "a".write(to: vault.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: vault.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: vault.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: vault)
        _ = try git(["commit", "-q", "-m", "test commit with 3 files"], in: vault)

        let runner = GitRunner(repoRoot: vault)
        let s = try runner.lastCommitSummary()

        XCTAssertEqual(s.shortHash.count, 7, "shortHash 7 字符")
        XCTAssertEqual(s.subject, "test commit with 3 files", "subject = commit msg 第一行")
        XCTAssertEqual(s.changedFiles, 3, "changedFiles = 3")
        XCTAssertTrue(s.author.contains("Test"), "author 含 Test")
    }

    func testLastCommitSummary_handlesMultiLineMessage() throws {
        let vault = makeTmpVault()
        try "x".write(to: vault.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: vault)
        _ = try git(["commit", "-q", "-m", "subject line\n\nbody line 1\nbody line 2"], in: vault)

        let runner = GitRunner(repoRoot: vault)
        let s = try runner.lastCommitSummary()
        XCTAssertEqual(s.subject, "subject line", "subject 只取第一行")
        XCTAssertTrue(s.fullMessage.contains("body line 1"))
        XCTAssertTrue(s.fullMessage.contains("body line 2"))
    }

    func testLastCommitSummary_throwsOnEmptyRepo() throws {
        let vault = makeTmpVault()
        let runner = GitRunner(repoRoot: vault)
        // 空 repo 没 HEAD → log -1 必抛
        XCTAssertThrowsError(try runner.lastCommitSummary())
    }
}
