import XCTest
@testable import DreamEngine
@testable import dream
import AppKit

@MainActor
final class LaunchCorrectnessTests: XCTestCase {

    // MARK: - P0-2: GitStatusWatcher.relPath 用完整 vault-relative 路径

    func testRelPath_nestedFile_resolvesFullPath() {
        let w = GitStatusWatcher()
        let vault = URL(fileURLWithPath: "/Users/test/vault", isDirectory: true)

        // 模拟 git 返回 "wiki/concepts/a.md" dirty
        w._setStatusesForTest(["wiki/concepts/a.md": .modified,
                               "wiki/archive/b.md": .staged,
                               "MEMORY.md": .modified],
                              vaultRoot: vault)

        // 完整路径应能命中
        let nestedA = vault.appendingPathComponent("wiki/concepts/a.md")
        let nestedB = vault.appendingPathComponent("wiki/archive/b.md")
        let mem = vault.appendingPathComponent("MEMORY.md")

        XCTAssertEqual(w.status(for: nestedA), .modified)
        XCTAssertEqual(w.status(for: nestedB), .staged)
        XCTAssertEqual(w.status(for: mem), .modified)

        // 重名文件（不同目录）应互不干扰
        let conflictA1 = vault.appendingPathComponent("wiki/concepts/index.md")
        let conflictA2 = vault.appendingPathComponent("wiki/syntheses/index.md")
        w._setStatusesForTest(["wiki/concepts/index.md": .modified,
                               "wiki/syntheses/index.md": .conflict],
                              vaultRoot: vault)
        XCTAssertEqual(w.status(for: conflictA1), .modified)
        XCTAssertEqual(w.status(for: conflictA2), .conflict)
    }

    func testRelPath_fileOutsideVault_isClean() {
        // 路径不在 vault 下 → 返回 .clean（不误报 dirty）
        let w = GitStatusWatcher()
        let vault = URL(fileURLWithPath: "/Users/test/vault", isDirectory: true)
        w._setStatusesForTest(["wiki/concepts/a.md": .modified], vaultRoot: vault)

        let outside = URL(fileURLWithPath: "/Users/other/a.md")
        XCTAssertEqual(w.status(for: outside), .clean)
    }

    func testRelPath_noVaultRefresh_isClean() {
        // refresh 都没跑过 → 不 crash
        let w = GitStatusWatcher()
        let any = URL(fileURLWithPath: "/Users/test/vault/wiki/x.md")
        XCTAssertEqual(w.status(for: any), .clean)
    }

    func testUpdateDiff_usesFullRelPath() {
        // 用真实 vault + git 写一个文件 → refresh → updateDiff → diff summary
        let vault = makeTmpVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        // **先建目录再 git init**，否则 git 看不到后续的子目录文件
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent("wiki/concepts"),
                                                 withIntermediateDirectories: true)
        let git = GitRunner(repoRoot: vault)
        try? git.run(["init"])
        try? git.run(["config", "user.email", "test@dreamvault.local"])
        try? git.run(["config", "user.name", "DreamVault"])
        let clean = "# hello\n"
        let f = vault.appendingPathComponent("wiki/concepts/note.md")
        try? clean.write(to: f, atomically: true, encoding: .utf8)
        try? git.run(["add", "."])
        try? git.run(["commit", "-m", "baseline"])

        // 改了文件
        let dirty = "# hello\nworld\n"
        try? dirty.write(to: f, atomically: true, encoding: .utf8)

        // watcher 拿 status + diff
        let w = GitStatusWatcher()
        w.refresh(vaultRoot: vault)
        w.updateDiff(for: f, vaultRoot: vault)

        XCTAssertEqual(w.status(for: f), .modified, "nested path must be detected as modified")
        let summary = w.diffSummary(for: f)
        XCTAssertNotNil(summary)
        XCTAssertGreaterThan(summary!.added, 0)
    }

    // MARK: - P0-3: AppDelegate 启动 chmod 用对的 vault
    // 抽个 helper 测（共享的解析函数）

    func testResolveInitialVault_prefersUserDefaults() {
        // 清理 + 设 UserDefaults
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        UserDefaults.standard.set("/Users/custom/vault", forKey: "DreamVaultInitialVault")
        defer { UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault") }

        let resolved = DreamEntry.resolveInitialVault()
        XCTAssertEqual(resolved.path, "/Users/custom/vault")
    }

    func testResolveInitialVault_fallsBackToDefault() {
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        // env 不动（DREAMVAULT_VAULT 在 test runner 可能没设）
        let resolved = DreamEntry.resolveInitialVault()
        // 至少应能解析到一个 URL（不崩），path 非空
        XCTAssertFalse(resolved.path.isEmpty)
    }

    // MARK: - P0-1: Run Dream 前 flush

    func testEditorState_flushIfDirty_writesToDisk() {
        // 真实文件 + dirty buffer → flushIfDirty → 文件应同步到磁盘
        let vault = makeTmpVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let f = vault.appendingPathComponent("note.md")
        try? "original".write(to: f, atomically: true, encoding: .utf8)

        let es = EditorState()
        es.openFile(f)
        es.buffer = "edited content"
        XCTAssertTrue(es.isDirty)

        let flushed = es.flushIfDirty()
        XCTAssertTrue(flushed)
        XCTAssertFalse(es.isDirty)

        // 磁盘应该是新内容
        let onDisk = try? String(contentsOf: f, encoding: .utf8)
        XCTAssertEqual(onDisk, "edited content")
    }

    // MARK: - helper

    private func makeTmpVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p0-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
