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
        _ = try? git.run(["init"])
        _ = try? git.run(["config", "user.email", "test@dreamvault.local"])
        _ = try? git.run(["config", "user.name", "DreamVault"])
        let clean = "# hello\n"
        let f = vault.appendingPathComponent("wiki/concepts/note.md")
        try? clean.write(to: f, atomically: true, encoding: .utf8)
        _ = try? git.run(["add", "."])
        _ = try? git.run(["commit", "-m", "baseline"])

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
        DreamEntry.resetLaunchVaultForTesting()
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        UserDefaults.standard.set("/Users/custom/vault", forKey: "DreamVaultInitialVault")
        defer {
            UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
            DreamEntry.resetLaunchVaultForTesting()
        }

        let resolved = DreamEntry.resolveInitialVault()
        XCTAssertEqual(resolved.path, "/Users/custom/vault")
    }

    func testResolveInitialVault_fallsBackToDefault() {
        DreamEntry.resetLaunchVaultForTesting()
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        // env 不动（DREAMVAULT_VAULT 在 test runner 可能没设）
        let resolved = DreamEntry.resolveInitialVault()
        // 至少应能解析到一个 URL（不崩），path 非空
        XCTAssertFalse(resolved.path.isEmpty)
    }

    func testAppModelInit_keepsLaunchVaultAfterAppDelegateClearsLegacyKey() {
        DreamEntry.resetLaunchVaultForTesting()
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        UserDefaults.standard.set("/Users/custom/vault", forKey: "DreamVaultInitialVault")
        defer {
            UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
            DreamEntry.resetLaunchVaultForTesting()
        }

        let delegateVault = DreamEntry.resolveInitialVault()
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")

        let model = AppModel()

        XCTAssertEqual(delegateVault.path, "/Users/custom/vault")
        XCTAssertEqual(model.vaultRoot.path, delegateVault.path)
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

    // MARK: - P8: CLI 路由修复
    //
    // 之前 Entry.swift 把任何不在 cliSubcommands 里的 firstArg 都丢进 GUI。
    // 这导致 `dream init` / `dream nonsense` 误启 SwiftUI 窗口。
    // 新规则：firstArg 是 nil / "app" 走 GUI，其他一律 CLI。

    func testRoute_nilFirstArg_goesGUI() {
        // 双击 / Finder / Spotlight 启动：firstArg == nil
        XCTAssertFalse(DreamEntry.isCLIRoute(nil), "nil 应该进 GUI 启动 SwiftUI")
    }

    func testRoute_appToken_goesGUI() {
        // 显式 `dream app`
        XCTAssertFalse(DreamEntry.isCLIRoute("app"), "'app' 应该进 GUI")
    }

    func testRoute_launchServicesProcessSerialNumber_goesGUI() {
        // `open -n DreamVault.app --args ...` 可能在用户参数前注入 -psn_...
        XCTAssertFalse(DreamEntry.isCLIRoute("-psn_0_123456"), "LaunchServices 的 -psn_ 参数应视作 GUI 启动")
    }

    func testRoute_regularFlag_goesCLI() {
        XCTAssertTrue(DreamEntry.isCLIRoute("--help"), "普通 CLI flag 仍应交给 CLI 处理，不能泛化成所有 '-' 都进 GUI")
    }

    func testRoute_knownSubcommand_goesCLI() {
        let known: Set<String> = ["run", "rollback", "status", "report", "help", "version"]
        for sub in known {
            XCTAssertTrue(DreamEntry.isCLIRoute(sub), "已知 CLI 子命令 '\(sub)' 应该进 CLI")
        }
    }

    func testRoute_unknownSubcommand_nowGoesCLI() {
        // P8 关键修复：未知子命令不再偷偷启 GUI
        for bad in ["nonsense", "init", "random", "version123", "helpme"] {
            XCTAssertTrue(DreamEntry.isCLIRoute(bad),
                          "未知子命令 '\(bad)' 应该进 CLI 走 default 报错，不再启 GUI")
        }
    }

    func testLaunchDisablesWindowStateRestoration() {
        let oldIgnoreState = UserDefaults.standard.object(forKey: "ApplePersistenceIgnoreState")
        let oldKeepsWindows = UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows")
        defer {
            restoreUserDefault(oldIgnoreState, forKey: "ApplePersistenceIgnoreState")
            restoreUserDefault(oldKeepsWindows, forKey: "NSQuitAlwaysKeepsWindows")
        }

        DreamEntry.configureWindowRestorationForLaunch()

        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"),
            "禁用窗口状态恢复时 ApplePersistenceIgnoreState 必须为 true，否则 open 启动可能恢复到 0 窗口状态"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows"),
            "关闭最后窗口后不应保留窗口恢复状态"
        )
    }

    // MARK: - GUI verify script

    func testBuildAndRunVerify_checksVisibleDreamVaultWindow() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(
            script.contains("AX GUI window"),
            "--verify 应检查 DreamVault GUI window，而不只是检查进程参数"
        )
        XCTAssertTrue(
            script.contains("FAIL=1"),
            "GUI window 缺失时 verify 必须失败"
        )
        XCTAssertTrue(
            script.contains("first process whose unix id is $PID"),
            "--verify 的 AX window 检查必须绑定当前 dev PID，不能误把已打开的正式版 DreamVault 窗口当作通过"
        )
    }

    func testBuildAndRunUsesStableDevAppPathForTCC() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(
            script.contains("""
            if [ "$KEEP" = "1" ]; then
                TMP_APP="/tmp/DreamVault-dev-$TIMESTAMP.app"
            else
                TMP_APP="$HOME/Applications/DreamVault-dev.app"
            fi
            """),
            "默认开发包路径应稳定，避免每次时间戳 app 都重新触发 macOS TCC 权限和 Computer Use 识别歧义"
        )
    }

    func testBuildAndRunFindsPIDForCurrentBundlePath() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(
            script.contains("pgrep -f \"$MACOS_BIN\""),
            "PID 查找必须限定当前 .app 的 binary 路径，不能抓第一个 DreamVault 旧进程"
        )
    }

    func testBuildAndRunStopsExistingDevAppBeforeRebuild() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(
            script.contains("EXISTING_BIN=\"$TMP_APP/Contents/MacOS/DreamVault\""),
            "重建稳定 dev app 前必须定位旧 dev binary，避免覆盖仍在运行的 .app"
        )
        XCTAssertTrue(
            script.contains("pgrep -f \"$EXISTING_BIN\""),
            "启动新 dev 前必须停止旧 dev 进程，否则 --verify 可能抓到旧 PID"
        )
    }

    // MARK: - helper

    private func restoreUserDefault(_ oldValue: Any?, forKey key: String) {
        if let oldValue {
            UserDefaults.standard.set(oldValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTmpVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p0-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
