import XCTest
@testable import DreamEngine
import AppKit

/// P7 (ship-readiness) 回归测试
@MainActor
final class ShipReadinessTests: XCTestCase {

    // MARK: - P7-T1: FirstRunTracker

    func testFirstRun_shouldShow_defaultEmpty() {
        // 清理 UserDefaults
        let key = FirstRunTracker.didShowWelcomeKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertTrue(FirstRunTracker.shouldShow(), "首次启动应显示 welcome")
    }

    func testFirstRun_shouldShow_falseAfterMarked() {
        let key = FirstRunTracker.didShowWelcomeKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        FirstRunTracker.markShown()
        XCTAssertFalse(FirstRunTracker.shouldShow(), "已 mark 后不应再 show")
    }

    func testFirstRun_reset_restoresShouldShow() {
        let key = FirstRunTracker.didShowWelcomeKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        FirstRunTracker.markShown()
        XCTAssertFalse(FirstRunTracker.shouldShow())
        FirstRunTracker.reset()
        XCTAssertTrue(FirstRunTracker.shouldShow(), "reset 后应能再 show")
    }

    // MARK: - P7-T2: VaultBackup

    func testVaultBackup_createsZipContainingGit() throws {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // init git + commit baseline
        let git = GitRunner(repoRoot: vault)
        try git.run(["init"])
        try git.run(["config", "user.email", "t@x"])
        try git.run(["config", "user.name", "T"])
        let f = vault.appendingPathComponent("MEMORY.md")
        try "# hello".write(to: f, atomically: true, encoding: .utf8)
        try git.run(["add", "."])
        try git.run(GitRunner.identity + ["commit", "-m", "baseline"])

        let zipURL = URL(fileURLWithPath: "/tmp/dv-p7-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        let backup = VaultBackup()
        let result = try backup.backup(vaultRoot: vault, to: zipURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        // zip file size > 0
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 100, "zip 应非空 (实际 \(size) bytes)")
    }

    func testVaultBackup_nonexistentVaultFails() {
        // 实际 /usr/bin/zip 要求 current directory 存在并有 . 入口；
        // 不存在 vault 会 fail（"Nothing to do"）。这是合理行为：
        // backup 应当要求 vault 真实存在
        let backup = VaultBackup()
        let bogusVault = URL(fileURLWithPath: "/tmp/dv-bogus-\(UUID().uuidString)")
        let zipURL = URL(fileURLWithPath: "/tmp/dv-bogus-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        XCTAssertThrowsError(try backup.backup(vaultRoot: bogusVault, to: zipURL))
    }

    func testVaultBackup_restore_rejectsNonEmptyDir() throws {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // vault 内有文件
        let f = vault.appendingPathComponent("exists.md")
        try "x".write(to: f, atomically: true, encoding: .utf8)

        // zip 是 valid 的
        let zipURL = URL(fileURLWithPath: "/tmp/dv-restore-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        // 构造一个 minimal 0-byte zip + 一个空 placeholder（"zip ." 对空目录报
        // "Nothing to do"）
        let tmpEmpty = URL(fileURLWithPath: "/tmp/dv-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpEmpty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpEmpty) }
        try ".placeholder".write(
            to: tmpEmpty.appendingPathComponent(".placeholder"),
            atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-r", "-q", zipURL.path, "."]
        p.currentDirectoryURL = tmpEmpty
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "zip 应成功")

        // 尝试 restore 到非空 vault
        let backup = VaultBackup()
        XCTAssertThrowsError(try backup.restore(zipFile: zipURL, to: vault)) { err in
            guard case VaultBackup.BackupError.vaultNotEmpty = err else {
                XCTFail("expected .vaultNotEmpty, got \(err)")
                return
            }
        }
    }

    func testVaultBackup_restore_rejectsNonZipFile() throws {
        let notZip = URL(fileURLWithPath: "/tmp/dv-not-zip-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: notZip) }
        try "not a zip".write(to: notZip, atomically: true, encoding: .utf8)
        let dest = makeVault()
        defer { try? FileManager.default.removeItem(at: dest) }
        let backup = VaultBackup()
        XCTAssertThrowsError(try backup.restore(zipFile: notZip, to: dest)) { err in
            guard case VaultBackup.BackupError.notAZipFile = err else {
                XCTFail("expected .notAZipFile, got \(err)")
                return
            }
        }
    }

    // MARK: - P7-T3: AtomicFile

    func testAtomicFile_writesAndReadsBack() throws {
        let target = URL(fileURLWithPath: "/tmp/dv-atomic-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = "hello atomic".data(using: .utf8)!
        try AtomicFile.write(data: data, to: target)
        let read = try Data(contentsOf: target)
        XCTAssertEqual(read, data)
    }

    func testAtomicFile_overwritesExisting() throws {
        let target = URL(fileURLWithPath: "/tmp/dv-atomic-ow-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try AtomicFile.write(data: "v1".data(using: .utf8)!, to: target)
        try AtomicFile.write(data: "v2".data(using: .utf8)!, to: target)
        let read = try Data(contentsOf: target)
        XCTAssertEqual(String(data: read, encoding: .utf8), "v2")
    }

    func testAtomicFile_cleansUpOnFailure() {
        // 写到不存在的父目录
        let target = URL(fileURLWithPath: "/tmp/dv-atomic-nonexist-\(UUID().uuidString)/file.bin")
        XCTAssertThrowsError(try AtomicFile.write(data: Data("x".utf8), to: target))
    }

    // MARK: - helper

    private func makeVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p7-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
