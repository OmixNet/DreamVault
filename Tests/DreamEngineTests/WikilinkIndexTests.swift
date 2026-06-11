import XCTest
@testable import DreamEngine

final class WikilinkIndexTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wikilink-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - extractWikilinks 纯函数

    func testExtract_simple() {
        let links = WikilinkIndex.extractWikilinks(from: "See [[other]] for details")
        XCTAssertEqual(links, [.init(target: "other", label: "other", line: 1)])
    }

    func testExtract_withAlias() {
        let links = WikilinkIndex.extractWikilinks(from: "Link: [[target|display]]")
        XCTAssertEqual(links, [.init(target: "target", label: "display", line: 1)])
    }

    func testExtract_multipleInOneLine() {
        let links = WikilinkIndex.extractWikilinks(from: "[[a]] and [[b]] and [[c|see C]]")
        XCTAssertEqual(links.map(\.target), ["a", "b", "c"])
        XCTAssertEqual(links.map(\.label), ["a", "b", "see C"])
    }

    func testExtract_multipleLines() {
        let md = """
        line 1 has [[foo]]
        line 2 has [[bar]]
        line 3 no link
        """
        let links = WikilinkIndex.extractWikilinks(from: md)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].line, 1)
        XCTAssertEqual(links[1].line, 2)
    }

    func testExtract_unclosedBracketsIgnored() {
        let links = WikilinkIndex.extractWikilinks(from: "broken [[unfinished")
        XCTAssertTrue(links.isEmpty)
    }

    func testExtract_emptyIgnored() {
        let links = WikilinkIndex.extractWikilinks(from: "broken [[]]")
        XCTAssertTrue(links.isEmpty, "空 wikilink 应忽略")
    }

    // MARK: - parseWikilink 纯函数

    func testParseWikilink_noAlias() {
        let (target, label) = WikilinkIndex.parseWikilink("id")
        XCTAssertEqual(target, "id")
        XCTAssertEqual(label, "id")
    }

    func testParseWikilink_withAlias() {
        let (target, label) = WikilinkIndex.parseWikilink("id|Display")
        XCTAssertEqual(target, "id")
        XCTAssertEqual(label, "Display")
    }

    func testParseWikilink_pathStyle() {
        let (target, label) = WikilinkIndex.parseWikilink("wiki/concepts/foo")
        XCTAssertEqual(target, "wiki/concepts/foo")
    }

    // MARK: - 扫 vault

    func testScan_vault_basic() throws {
        // a.md → [[b]]
        // b.md → [[c|see C]]（自指 + 指向 c）
        // c.md → 无链接
        // raw/d.md → [[d]]（应被排除，raw/ 不在索引里）
        try "see [[b]] for context".write(to: tempDir.appendingPathComponent("a.md"),
                                          atomically: true, encoding: .utf8)
        try "links to [[c|see C]]".write(to: tempDir.appendingPathComponent("b.md"),
                                         atomically: true, encoding: .utf8)
        try "no link here".write(to: tempDir.appendingPathComponent("c.md"),
                                 atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("raw"),
                                               withIntermediateDirectories: true)
        try "raw [[d]]".write(to: tempDir.appendingPathComponent("raw/d.md"),
                               atomically: true, encoding: .utf8)

        var index = WikilinkIndex()
        try index.scan(vaultRoot: tempDir)

        // 3 entries (a/b/c)，raw/d.md 不算
        XCTAssertEqual(Set(index.entries.keys), Set(["a.md", "b.md", "c.md"]))

        // a → b
        XCTAssertEqual(index.entries["a.md"]?.outlinks.map(\.target), ["b"])
        // b → c with alias
        XCTAssertEqual(index.entries["b.md"]?.outlinks.map(\.label), ["see C"])

        // backLinks: b 来自 a；c 来自 b
        XCTAssertEqual(Set(index.backLinks.keys), Set(["b", "c"]))
        XCTAssertEqual(index.backLinks(for: "b"), ["a.md"])
        XCTAssertEqual(index.backLinks(for: "c"), ["b.md"])
    }

    func testScan_excludes_dotDirs() throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".dream"),
                                               withIntermediateDirectories: true)
        try "see [[foo]]".write(to: tempDir.appendingPathComponent(".dream/should-skip.md"),
                               atomically: true, encoding: .utf8)
        try "no link".write(to: tempDir.appendingPathComponent("real.md"),
                            atomically: true, encoding: .utf8)
        var index = WikilinkIndex()
        try index.scan(vaultRoot: tempDir)
        XCTAssertFalse(index.entries.keys.contains(".dream/should-skip.md"))
        XCTAssertTrue(index.entries.keys.contains("real.md"))
    }

    func testUpdateFile_changesOutlinks() throws {
        let aURL = tempDir.appendingPathComponent("a.md")
        let bURL = tempDir.appendingPathComponent("b.md")
        try "see [[b]]".write(to: aURL, atomically: true, encoding: .utf8)
        try "body".write(to: bURL, atomically: true, encoding: .utf8)

        var index = WikilinkIndex()
        try index.scan(vaultRoot: tempDir)
        XCTAssertEqual(index.backLinks(for: "b"), ["a.md"])

        // a 改文案，wikilink 改成 [[c]]
        try "now links [[c]]".write(to: aURL, atomically: true, encoding: .utf8)
        try index.updateFile(at: aURL, vaultRoot: tempDir)
        XCTAssertEqual(index.backLinks(for: "b"), [], "旧 b 引用应清空")
        XCTAssertEqual(index.backLinks(for: "c"), ["a.md"])
    }

    func testRemoveFile_cleansBackLinks() throws {
        let aURL = tempDir.appendingPathComponent("a.md")
        let bURL = tempDir.appendingPathComponent("b.md")
        try "see [[b]]".write(to: aURL, atomically: true, encoding: .utf8)
        try "body".write(to: bURL, atomically: true, encoding: .utf8)

        var index = WikilinkIndex()
        try index.scan(vaultRoot: tempDir)
        XCTAssertEqual(index.backLinks(for: "b"), ["a.md"])

        index.removeFile(at: aURL, vaultRoot: tempDir)
        XCTAssertEqual(index.backLinks(for: "b"), [])
        XCTAssertNil(index.entries["a.md"])
    }

    func testResolveTarget_caseInsensitive() throws {
        try "see [[Hello-World]]".write(to: tempDir.appendingPathComponent("a.md"),
                                        atomically: true, encoding: .utf8)
        try "body".write(to: tempDir.appendingPathComponent("hello-world.md"),
                         atomically: true, encoding: .utf8)
        var index = WikilinkIndex()
        try index.scan(vaultRoot: tempDir)
        // 大小写不敏感查找
        XCTAssertNotNil(index.resolveTarget("hello-world"))
        XCTAssertNotNil(index.resolveTarget("Hello-World"))
    }
}
