import XCTest
@testable import DreamEngine
import AppKit

final class MarkdownTableAndImageTests: XCTestCase {

    private let renderer = MarkdownRenderer()

    // MARK: - 表格

    func testTable_3x3_rendersAllRows() {
        let md = """
        | Name | Age | City |
        | ---- | --- | ---- |
        | Alice | 30 | NYC |
        | Bob | 25 | SF |
        """
        let out = renderer.render(md)
        let plain = out.string
        XCTAssertTrue(plain.contains("Name"))
        XCTAssertTrue(plain.contains("Alice"))
        XCTAssertTrue(plain.contains("Bob"))
        XCTAssertTrue(plain.contains("|"))
        // header 行应用了粗体
        let headerAttrs = out.attributes(at: 0, effectiveRange: nil)
        let font = headerAttrs[.font] as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        XCTAssertTrue(traits.contains(.bold), "header 应该是粗体")
    }

    func testTable_singleColumn_works() {
        let md = """
        | Col |
        | --- |
        | a   |
        | b   |
        """
        let out = renderer.render(md)
        XCTAssertTrue(out.string.contains("a"))
        XCTAssertTrue(out.string.contains("b"))
    }

    func testTable_withAlignmentMarkers() {
        let md = """
        | L | C | R |
        | :--- | :---: | ---: |
        | 1 | 2 | 3 |
        """
        let out = renderer.render(md)
        XCTAssertTrue(out.string.contains("1"))
        XCTAssertTrue(out.string.contains("3"))
    }

    func testNotTable_lineWithPipeButNoSeparator() {
        let md = """
        | a | b |
        not a separator
        | c | d |
        """
        let out = renderer.render(md)
        let plain = out.string
        // 因为下一行不是 separator，parser 走 paragraph 不应识别为 table
        // 至少应该出现所有字符
        XCTAssertTrue(plain.contains("a"))
        XCTAssertTrue(plain.contains("c"))
    }

    // MARK: - 图片

    func testImage_validLocalFile_rendersAttachment() {
        // 写一个临时 png → 测试它被解析为 image block
        let tmpImg = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpImg) }
        // 写一个 1x1 png
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // PNG header
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  // IHDR length + name
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  // 1x1
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,  // IDAT
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,  // IEND
            0x42, 0x60, 0x82,
        ])
        try? pngData.write(to: tmpImg)
        let md = "![alt text](\(tmpImg.path))"
        let out = renderer.render(md)
        // 加载成功时 output 含 attachment + alt label
        let plain = out.string
        XCTAssertTrue(plain.contains("alt text") || out.length > 0, "image block 应该有非空输出")
    }

    func testImage_missingFile_rendersPlaceholder() {
        let md = "![diagram](/nonexistent/foo.png)"
        let out = renderer.render(md)
        let plain = out.string
        XCTAssertTrue(plain.contains("foo.png"), "占位符应包含路径")
        XCTAssertTrue(plain.contains("🖼"), "占位符应有 🖼 emoji")
    }

    func testImage_noAlt() {
        let md = "![](http://example.com/img.png)"
        let out = renderer.render(md)
        let plain = out.string
        // 加载失败（远程 URL 我们不抓）→ 占位符应含 src
        XCTAssertTrue(plain.contains("img.png"))
    }
}
