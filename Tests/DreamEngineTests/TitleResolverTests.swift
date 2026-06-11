import XCTest
@testable import DreamEngine

/// TitleResolver 单元测试（arch doc 不强制 schema，但需要稳定可预测的命名规则）。
final class TitleResolverTests: XCTestCase {

    // MARK: - classify

    func testClassify_raw_isRaw() {
        XCTAssertEqual(TitleResolver.classify(relPath: "raw/2026-06-11-x.md"), .raw)
        XCTAssertEqual(TitleResolver.classify(relPath: "raw/sub/foo.md"), .raw)
    }

    func testClassify_memoryMd() {
        XCTAssertEqual(TitleResolver.classify(relPath: "MEMORY.md"), .memoryMd)
    }

    func testClassify_wikiMemory_allThreeSubdirs() {
        XCTAssertEqual(TitleResolver.classify(relPath: "wiki/concepts/abc-123.md"), .wikiMemory)
        XCTAssertEqual(TitleResolver.classify(relPath: "wiki/entities/Person-A.md"), .wikiMemory)
        XCTAssertEqual(TitleResolver.classify(relPath: "wiki/syntheses/Topic-X.md"), .wikiMemory)
    }

    func testClassify_plainNote() {
        XCTAssertEqual(TitleResolver.classify(relPath: "notes.md"), .plainNote)
        XCTAssertEqual(TitleResolver.classify(relPath: "journal/2026-06-11.md"), .plainNote)
    }

    // MARK: - canRename

    func testCanRename_raw_isFalse() {
        XCTAssertFalse(TitleResolver.canRename(relPath: "raw/x.md"),
                       "arch doc 0.1 raw 永远不动文件名")
    }

    func testCanRename_wiki_isTrue() {
        XCTAssertTrue(TitleResolver.canRename(relPath: "wiki/concepts/abc.md"))
    }

    func testCanRename_plain_isTrue() {
        XCTAssertTrue(TitleResolver.canRename(relPath: "notes.md"))
    }

    // MARK: - displayTitle

    func testDisplayTitle_frontmatterTitle_wins() {
        let front = FrontmatterParser().parse("""
        ---
        title: My Real Title
        ---
        # Wrong Header
        body
        """)
        let title = TitleResolver.displayTitle(
            relPath: "notes.md",
            frontmatter: front,
            body: "# Wrong Header\nbody"
        )
        XCTAssertEqual(title, "My Real Title")
    }

    func testDisplayTitle_fallbackToH1() {
        let front = FrontmatterParser().parse("body without frontmatter")
        let title = TitleResolver.displayTitle(
            relPath: "notes.md",
            frontmatter: front,
            body: "# First H1\nbody"
        )
        XCTAssertEqual(title, "First H1")
    }

    func testDisplayTitle_fallbackToFilename() {
        let title = TitleResolver.displayTitle(
            relPath: "my-cool-note.md",
            frontmatter: nil,
            body: "no header here"
        )
        XCTAssertEqual(title, "my-cool-note")
    }

    func testDisplayTitle_raw_usesFilename() {
        // raw 文件不解析 frontmatter，直接用文件名
        let front = FrontmatterParser().parse("""
        ---
        title: Misleading
        ---
        """)
        let title = TitleResolver.displayTitle(
            relPath: "raw/2026-06-11-x.md",
            frontmatter: front,
            body: "body"
        )
        XCTAssertEqual(title, "2026-06-11-x.md")
    }

    func testDisplayTitle_emptyTitleField_fallsThrough() {
        let front = FrontmatterParser().parse("""
        ---
        title:
        ---
        # Actual H1
        body
        """)
        let title = TitleResolver.displayTitle(
            relPath: "notes.md",
            frontmatter: front,
            body: "# Actual H1\nbody"
        )
        XCTAssertEqual(title, "Actual H1")
    }

    // MARK: - firstH1

    func testFirstH1_basic() {
        XCTAssertEqual(TitleResolver.firstH1("# Hello\nbody"), "Hello")
    }

    func testFirstH1_ignoresH2() {
        XCTAssertEqual(TitleResolver.firstH1("## Subheading\nbody"), nil)
    }

    func testFirstH1_firstWins() {
        let h1 = TitleResolver.firstH1("# First\n\n# Second")
        XCTAssertEqual(h1, "First")
    }

    func testFirstH1_empty() {
        XCTAssertNil(TitleResolver.firstH1("body without h1"))
    }

    // MARK: - suggestFilename

    func testSuggestFilename_kebabCase() {
        XCTAssertEqual(TitleResolver.suggestFilename(from: "My Cool Note"),
                       "my-cool-note.md")
    }

    func testSuggestFilename_removesSpecialChars() {
        XCTAssertEqual(TitleResolver.suggestFilename(from: "What's the *real* deal?!"),
                       "what-s-the-real-deal.md")
    }

    func testSuggestFilename_collapseDashes() {
        XCTAssertEqual(TitleResolver.suggestFilename(from: "Foo  &  Bar"),
                       "foo-bar.md")
    }
}
