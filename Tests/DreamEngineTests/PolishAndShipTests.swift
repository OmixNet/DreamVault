import XCTest
@testable import DreamEngine
import AppKit

/// P5 (polish) + P6 (publish) 回归测试
@MainActor
final class PolishAndShipTests: XCTestCase {

    // MARK: - P5-T1: GitRunner.revertLastCommit

    func testGitRunner_revertLastCommit_createsInverseCommit() throws {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // init + 第一次 commit baseline
        let git = GitRunner(repoRoot: vault)
        try git.run(["init"])
        try git.run(["config", "user.email", "t@x"])
        try git.run(["config", "user.name", "T"])
        let f = vault.appendingPathComponent("a.md")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        try git.run(["add", "."])
        try git.run(GitRunner.identity + ["commit", "-m", "v1"])
        let head1 = try git.headHash()
        // 第二次 commit
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        try git.run(["add", "."])
        try git.run(GitRunner.identity + ["commit", "-m", "v2"])
        let head2 = try git.headHash()
        XCTAssertNotEqual(head1, head2)
        // revert
        let headAfterRevert = try git.revertLastCommit()
        XCTAssertNotEqual(headAfterRevert, head2, "revert 后 head 应变")
        // 文件应回到 v1
        let onDisk = try String(contentsOf: f, encoding: .utf8)
        XCTAssertEqual(onDisk, "v1", "revert 后文件应回到 v1")
    }

    // MARK: - P5-T2: ColorSchemeController

    func testColorSchemeController_defaultIsSystem() {
        // 第一次跑：UserDefaults 没设 → 应当是 .system
        // 隔离 UserDefaults
        let key = "DreamVault.colorSchemeOverride"
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev = prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let c = ColorSchemeController()
        XCTAssertEqual(c.mode, .system)
    }

    func testColorSchemeController_preferredSchemeForDark() {
        // preferredColorScheme: nil=system, .some(.light)=light, .some(.dark)=dark
        let prev = UserDefaults.standard.string(forKey: "DreamVault.colorSchemeOverride")
        defer {
            if let prev = prev {
                UserDefaults.standard.set(prev, forKey: "DreamVault.colorSchemeOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "DreamVault.colorSchemeOverride")
            }
        }
        UserDefaults.standard.set("dark", forKey: "DreamVault.colorSchemeOverride")
        let c = ColorSchemeController()
        XCTAssertEqual(c.mode, .dark)
        XCTAssertEqual(c.preferredColorScheme, .dark)
    }

    func testColorSchemeController_setPersistsToUserDefaults() {
        let key = "DreamVault.colorSchemeOverride"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let c = ColorSchemeController()
        c.mode = .light
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "light")
    }

    // MARK: - P6-T3: UpdateChecker semver compare

    func testUpdateChecker_isNewer_basic() {
        XCTAssertTrue(UpdateChecker.isNewer(latest: "0.3.0", current: "0.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer(latest: "1.0.0", current: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer(latest: "0.3.1", current: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer(latest: "0.3.0", current: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer(latest: "0.2.1", current: "0.3.0"))
    }

    func testUpdateChecker_isNewer_withVPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer(latest: "v0.3.0", current: "0.2.1"))
    }

    func testUpdateChecker_isNewer_malformedFallsBackToZero() {
        // "abc" parse 成 [0, 0, 0] → 0.3.0 > 0.0.0 → newer
        XCTAssertTrue(UpdateChecker.isNewer(latest: "0.3.0", current: "abc"))
    }

    func testUpdateChecker_initReadsCurrentVersionFromBundle() {
        let c = UpdateChecker(repo: "OmixNet/DreamVault", currentVersion: "0.3.0")
        let info = UpdateChecker.UpdateInfo(
            currentVersion: "0.3.0",
            latestVersion: "0.3.1",
            releaseURL: URL(string: "https://github.com/OmixNet/DreamVault/releases")!,
            releaseNotes: "test"
        )
        XCTAssertTrue(info.isUpdateAvailable)
    }

    // MARK: - P5-T2: UpdateInfo isUpdateAvailable

    func testUpdateInfo_isUpdateAvailable_usesSemver() {
        let i1 = UpdateChecker.UpdateInfo(
            currentVersion: "0.3.0",
            latestVersion: "0.3.1",
            releaseURL: URL(string: "https://example.com")!,
            releaseNotes: ""
        )
        XCTAssertTrue(i1.isUpdateAvailable)

        let i2 = UpdateChecker.UpdateInfo(
            currentVersion: "0.3.0",
            latestVersion: "0.2.9",
            releaseURL: URL(string: "https://example.com")!,
            releaseNotes: ""
        )
        XCTAssertFalse(i2.isUpdateAvailable)
    }

    // MARK: - helper

    private func makeVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
