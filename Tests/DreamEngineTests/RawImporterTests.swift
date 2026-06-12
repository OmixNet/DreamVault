import XCTest
@testable import DreamEngine

/// P9 P0-4: 拖拽 / 菜单 Import 落 raw/ 测试
final class RawImporterTests: XCTestCase {

    private func makeTmpVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p9-imp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSourceFile(content: String, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p9-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("note.\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 基础导入

    func testImport_succeedsForMarkdown() throws {
        let vault = makeTmpVault()
        let src = try makeSourceFile(content: "# Hello\n\nWorld", ext: "md")
        let result = RawImporter.importToRaw(sourceURLs: [src], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 1, ".md 应当被接受")
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        // 落地的内容
        let landed = result.succeeded[0]
        XCTAssertTrue(landed.path.contains("/raw/note.md"), "应该落 raw/note.md")
        let text = try String(contentsOf: landed, encoding: .utf8)
        XCTAssertTrue(text.contains("processed: false"), "frontmatter 应含 processed: false")
        XCTAssertTrue(text.contains("# Hello"), "原内容应保留")
    }

    func testImport_succeedsForTxt() throws {
        let vault = makeTmpVault()
        let src = try makeSourceFile(content: "raw notes", ext: "txt")
        let result = RawImporter.importToRaw(sourceURLs: [src], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 1, ".txt 应当被接受")
        let landed = result.succeeded[0]
        XCTAssertTrue(landed.path.hasSuffix(".txt"), "后缀保留")
    }

    // MARK: - 重名加后缀

    func testImport_renamesOnDuplicate() throws {
        let vault = makeTmpVault()
        // 第一次导入
        let src1 = try makeSourceFile(content: "first", ext: "md")
        _ = RawImporter.importToRaw(sourceURLs: [src1], vaultRoot: vault)
        // 第二次：同名 → 加日期后缀
        let src2 = try makeSourceFile(content: "second", ext: "md")
        let result = RawImporter.importToRaw(sourceURLs: [src2], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 1)
        let landed = result.succeeded[0]
        XCTAssertFalse(landed.lastPathComponent == "note.md",
                       "重名不应该覆盖, 应加日期后缀")
        XCTAssertTrue(landed.lastPathComponent.contains("note-"),
                      "应含 note- 前缀; 实际: \(landed.lastPathComponent)")
        // 验证原文件未被覆盖
        let original = vault.appendingPathComponent("raw/note.md")
        let firstText = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(firstText.contains("first"), "原文件内容不变")
    }

    // MARK: - 不支持的后缀

    func testImport_skipsUnsupportedExtension() throws {
        let vault = makeTmpVault()
        let src = try makeSourceFile(content: "binary", ext: "png")
        let result = RawImporter.importToRaw(sourceURLs: [src], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("png"), "skipped 应说明是 .png")
    }

    // MARK: - 混合批量

    func testImport_handlesMixedBatch() throws {
        let vault = makeTmpVault()
        let srcMd = try makeSourceFile(content: "md", ext: "md")
        let srcTxt = try makeSourceFile(content: "txt", ext: "txt")
        let srcPng = try makeSourceFile(content: "img", ext: "png")
        let result = RawImporter.importToRaw(sourceURLs: [srcMd, srcTxt, srcPng], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 2, "md + txt 进, png 跳")
        XCTAssertEqual(result.skipped.count, 1, "png 应该被 skip")
    }

    // MARK: - 已有 frontmatter 不覆盖

    func testImport_preservesExistingFrontmatter() throws {
        let vault = makeTmpVault()
        let content = """
        ---
        title: 我的笔记
        tags: [a, b]
        ---

        正文内容
        """
        let src = try makeSourceFile(content: content, ext: "md")
        let result = RawImporter.importToRaw(sourceURLs: [src], vaultRoot: vault)
        let landed = result.succeeded[0]
        let landedText = try String(contentsOf: landed, encoding: .utf8)
        XCTAssertTrue(landedText.contains("title: 我的笔记"), "原 frontmatter 保留")
        XCTAssertTrue(landedText.contains("tags: [a, b]"), "原 tags 保留")
        XCTAssertTrue(landedText.contains("正文内容"), "正文保留")
    }

    // MARK: - batch_id 一致性

    func testImport_sameBatch_getsSameBatchID() throws {
        let vault = makeTmpVault()
        let src1 = try makeSourceFile(content: "a", ext: "md")
        let src2 = try makeSourceFile(content: "b", ext: "md")
        let result = RawImporter.importToRaw(sourceURLs: [src1, src2], vaultRoot: vault)
        XCTAssertEqual(result.succeeded.count, 2)
        let text1 = try String(contentsOf: result.succeeded[0], encoding: .utf8)
        let text2 = try String(contentsOf: result.succeeded[1], encoding: .utf8)
        // 抓 batch_id 行
        let bid1 = text1.components(separatedBy: "\n").first(where: { $0.hasPrefix("batch_id:") })
        let bid2 = text2.components(separatedBy: "\n").first(where: { $0.hasPrefix("batch_id:") })
        XCTAssertNotNil(bid1, "应有 batch_id")
        XCTAssertEqual(bid1, bid2, "同批次 batch_id 必须一致")
    }

    // MARK: - uniqueDestination 单元测试

    func testUniqueDestination_noConflict() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p9-uniq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try? RawImporter.uniqueDestination(in: dir, original: "fresh.md")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lastPathComponent, "fresh.md")
    }

    func testUniqueDestination_onConflict_addsDateSuffix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p9-uniq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 预创建 note.md
        try "preexisting".write(to: dir.appendingPathComponent("note.md"),
                                atomically: true, encoding: .utf8)
        let result = try RawImporter.uniqueDestination(in: dir, original: "note.md")
        XCTAssertNotEqual(result.lastPathComponent, "note.md", "不应该覆盖")
        XCTAssertTrue(result.lastPathComponent.hasPrefix("note-"),
                      "应加 note- 前缀: \(result.lastPathComponent)")
    }
}
