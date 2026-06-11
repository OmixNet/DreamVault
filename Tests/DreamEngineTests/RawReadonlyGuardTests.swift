import XCTest
@testable import DreamEngine

/// RawReadonlyGuard 单元测试
///
/// 对应架构文档第 1 节末段：把"原则 1（raw/ 永远只读）"变成文件系统机制。
/// 这里验证：
///   1. makeReadonly 把 .md 文件从可写压到 0o555
///   2. isReadonly 正确反映当前权限
///   3. 权限被压后仍可读（保留 x bit 让 dream/Gatherer 能 traverse）
///   4. Gatherer 的防御性闸门在 raw 只读时抛 attemptToModifyRaw
final class RawReadonlyGuardTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dv-rraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("raw"),
            withIntermediateDirectories: true)
        tempDir = tmp
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            // 测试结束后若还压着只读，FileManager.removeItem 会失败——
            // 先 chmod 回可写再删
            try? Self.makeWritable(dir.appendingPathComponent("raw"))
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // 工具：把目录整棵压回可写（方便 teardown）
    private static func makeWritable(_ url: URL) throws {
        let fm = FileManager.default
        let mode = NSNumber(value: 0o755)
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        if let it = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            while let next = it.nextObject() as? URL {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: next.path)
            }
        }
    }

    // 工具：写一个 raw .md 并显式 chmod 644（确保测试起点是"可写"）
    private func writeRawFile(name: String, content: String) throws -> URL {
        let url = tempDir.appendingPathComponent("raw").appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
        return url
    }

    // 工具：读 posix mode
    private func currentMode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - 测试

    /// 1. makeReadonly 后所有 .md 文件的 posix 权限 = 0o555（不含 w bit）
    func testMakeReadonly_setsAllMdFilesTo0555() throws {
        let f1 = try writeRawFile(name: "a.md", content: "alpha")
        let f2 = try writeRawFile(name: "b.md", content: "beta")
        // 子目录里再加一个
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("raw/sub"),
            withIntermediateDirectories: true)
        let f3 = try writeRawFile(name: "sub/c.md", content: "gamma")
        // 起点确认可写
        XCTAssertEqual(currentMode(f1), 0o644)
        XCTAssertEqual(currentMode(f2), 0o644)
        XCTAssertEqual(currentMode(f3), 0o644)

        // 动作
        try RawReadonlyGuard.makeReadonly(vaultRoot: tempDir)

        // 期望：所有 .md 现在是 0o555（r-x r-x r-x）
        XCTAssertEqual(currentMode(f1), 0o555, "a.md 应被压到 0o555")
        XCTAssertEqual(currentMode(f2), 0o555, "b.md 应被压到 0o555")
        XCTAssertEqual(currentMode(f3), 0o555, "sub/c.md 应被压到 0o555")
        // raw/ 目录本身也应是 0o555（traverse OK，写不行）
        XCTAssertEqual(currentMode(tempDir.appendingPathComponent("raw")), 0o555)
    }

    /// 2. isReadonly 在 makeReadonly 后返回 true；可写时返回 false；
    ///    无 raw/ 或无 .md 时返回 false（"无需保护"语义）
    func testIsReadonly_reflectsPermissionState() throws {
        // 起点：无 .md → false
        XCTAssertFalse(RawReadonlyGuard.isReadonly(vaultRoot: tempDir))

        // 加一个可写的 .md → false
        _ = try writeRawFile(name: "a.md", content: "x")
        XCTAssertFalse(RawReadonlyGuard.isReadonly(vaultRoot: tempDir))

        // 压成只读 → true
        try RawReadonlyGuard.makeReadonly(vaultRoot: tempDir)
        XCTAssertTrue(RawReadonlyGuard.isReadonly(vaultRoot: tempDir),
                      "makeReadonly 后 isReadonly 应返回 true")

        // 手动 chmod 回可写 → false
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: tempDir.appendingPathComponent("raw/a.md").path
        )
        XCTAssertFalse(RawReadonlyGuard.isReadonly(vaultRoot: tempDir),
                       "手动 chmod +w 后 isReadonly 应返回 false")
    }

    /// 3. 权限压到 0o555 后仍可读（r bit + x bit 都在）
    ///    这是关键：dream/Gatherer 必须能 traverse + 读 raw，不能因为 chmod 把自己也锁了
    func testReadonlyFiles_areStillReadable() throws {
        let f = try writeRawFile(name: "a.md", content: """
        ---
        processed: false
        ---

        原始内容：这里只是被脱敏前的一段观察
        """)
        try RawReadonlyGuard.makeReadonly(vaultRoot: tempDir)

        // 验证可读
        let content = try String(contentsOf: f, encoding: .utf8)
        XCTAssertTrue(content.contains("原始内容"), "0o555 下 raw 文件仍可读")
        XCTAssertTrue(content.contains("processed: false"), "frontmatter 仍可读")

        // 验证不可写（FileManager.isWritableFile 应返回 false）
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: f.path),
                       "0o555 下 raw 文件应不可写")

        // 验证仍能 traverse 到子目录（x bit 保留）
        let rawDir = tempDir.appendingPathComponent("raw")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: rawDir.path),
                      "raw/ 目录应可读")
    }

    /// 4. Gatherer 的防御性闸门：raw 已挂只读时，任何"想往 raw 写"的调用都抛 attemptToModifyRaw
    ///    这是 Gatherer.swift 注释里那条架构原则的硬保险。
    func testGatherer_assertWillNotWriteBackToRaw_throwsWhenReadonly() throws {
        // 准备：一个 raw 文件 + 已挂只读
        _ = try writeRawFile(name: "a.md", content: "x")
        try RawReadonlyGuard.makeReadonly(vaultRoot: tempDir)

        // 触发防御性闸门
        XCTAssertThrowsError(
            try Gatherer.assertWillNotWriteBackToRaw(vaultRoot: tempDir, file: "a.md")
        ) { error in
            guard case Gatherer.GathererError.attemptToModifyRaw(let file) = error else {
                XCTFail("期望 attemptToModifyRaw，实际 \(error)")
                return
            }
            XCTAssertEqual(file, "a.md")
        }
    }

    /// 5. 反面：raw 没挂只读时，闸门不抛（让正常 refactor 留口子）
    func testGatherer_assertWillNotWriteBackToRaw_doesNotThrowWhenWritable() throws {
        _ = try writeRawFile(name: "a.md", content: "x")
        // 不调 makeReadonly — 文件保持 0o644（可写）
        XCTAssertNoThrow(
            try Gatherer.assertWillNotWriteBackToRaw(vaultRoot: tempDir, file: "a.md")
        )
    }

    /// 6. raw/ 不存在时不抛（幂等性 / 新 vault 友好）
    func testMakeReadonly_isIdempotentOnMissingRawDir() throws {
        let freshDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dv-rraw-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: freshDir) }

        // 不应抛
        XCTAssertNoThrow(try RawReadonlyGuard.makeReadonly(vaultRoot: freshDir))
        // 不存在时 isReadonly = false（"无需保护"）
        XCTAssertFalse(RawReadonlyGuard.isReadonly(vaultRoot: freshDir))
    }
}