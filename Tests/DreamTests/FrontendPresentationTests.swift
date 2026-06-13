import XCTest
@testable import dream

@MainActor
final class FrontendPresentationTests: XCTestCase {
    func testVaultDisplayNameUsesLastPathComponent() {
        XCTAssertEqual(FrontendPresentation.vaultDisplayName(path: "/Users/alex/Vaults/DreamVault"), "DreamVault")
    }

    func testVaultDisplayNameTrimsTrailingSlash() {
        XCTAssertEqual(FrontendPresentation.vaultDisplayName(path: "/Users/alex/Vaults/Research/"), "Research")
    }

    func testVaultDisplayNameFallsBackForRootPath() {
        XCTAssertEqual(FrontendPresentation.vaultDisplayName(path: "/"), "DreamVault")
    }

    func testVaultSubtitleAbbreviatesHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            FrontendPresentation.vaultSubtitle(path: "\(home)/DreamVault"),
            "~/DreamVault"
        )
    }

    func testBudgetUsageFormatsUnlimitedLimit() {
        XCTAssertEqual(FrontendPresentation.budgetUsage(count: 3, limit: 0), "3 / ∞ calls")
    }

    func testBudgetUsageFormatsFiniteLimit() {
        XCTAssertEqual(FrontendPresentation.budgetUsage(count: 3, limit: 10), "3 / 10 calls")
    }

    func testDocumentTitleUsesMarkdownHeadingForWikiFile() {
        XCTAssertEqual(
            FrontendPresentation.documentTitle(
                relPath: "wiki/concepts/cua-baseline.md",
                body: "# Better Concept\n\nBody"
            ),
            "Better Concept"
        )
    }

    func testDocumentTitleKeepsRawFilename() {
        XCTAssertEqual(
            FrontendPresentation.documentTitle(
                relPath: "raw/capture.md",
                body: "# Should Not Win"
            ),
            "capture.md"
        )
    }

    func testDocumentKindLabelsAreHumanReadable() {
        XCTAssertEqual(FrontendPresentation.documentKindLabel(relPath: "raw/capture.md"), "Raw")
        XCTAssertEqual(FrontendPresentation.documentKindLabel(relPath: "wiki/concepts/a.md"), "Wiki")
        XCTAssertEqual(FrontendPresentation.documentKindLabel(relPath: "MEMORY.md"), "Memory")
        XCTAssertEqual(FrontendPresentation.documentKindLabel(relPath: "notes/freeform.md"), "Note")
    }

    func testDocumentSaveStatusText() {
        XCTAssertEqual(FrontendPresentation.documentSaveStatus(isEditable: false, isDirty: true), "Read only")
        XCTAssertEqual(FrontendPresentation.documentSaveStatus(isEditable: true, isDirty: true), "Unsaved")
        XCTAssertEqual(FrontendPresentation.documentSaveStatus(isEditable: true, isDirty: false), "Saved")
    }

    func testSidebarAllowsRenameOnlyWhenTitleResolverDoes() {
        XCTAssertFalse(FrontendPresentation.canRenameSidebarItem(relPath: "raw/capture.md"))
        XCTAssertTrue(FrontendPresentation.canRenameSidebarItem(relPath: "wiki/concepts/a.md"))
    }

    func testSidebarTitleUsesReadableWikiHeading() {
        XCTAssertEqual(
            FrontendPresentation.sidebarTitle(
                relPath: "wiki/concepts/cua-baseline.md",
                body: "# CUA Baseline\n\nBody"
            ),
            "CUA Baseline"
        )
    }

    func testSidebarTitleKeepsRawFilename() {
        XCTAssertEqual(
            FrontendPresentation.sidebarTitle(
                relPath: "raw/capture.md",
                body: "# Should Not Win"
            ),
            "capture.md"
        )
    }

    func testSidebarSubtitleShowsRelativePathWhenUseful() {
        XCTAssertEqual(
            FrontendPresentation.sidebarSubtitle(relPath: "wiki/concepts/cua-baseline.md"),
            "wiki/concepts/cua-baseline.md"
        )
        XCTAssertNil(FrontendPresentation.sidebarSubtitle(relPath: "MEMORY.md"))
    }

    func testSearchResultTitleUsesReadableWikiHeading() {
        XCTAssertEqual(
            FrontendPresentation.searchResultTitle(
                relPath: "wiki/concepts/cua-baseline.md",
                body: "# Searchable Concept\n\nBody"
            ),
            "Searchable Concept"
        )
    }

    func testSearchResultTitleKeepsRawFilename() {
        XCTAssertEqual(
            FrontendPresentation.searchResultTitle(
                relPath: "raw/capture.md",
                body: "# Should Not Win"
            ),
            "capture.md"
        )
    }

    func testSearchResultSubtitleKeepsLocationForNestedNotes() {
        XCTAssertEqual(
            FrontendPresentation.searchResultSubtitle(relPath: "wiki/concepts/cua-baseline.md"),
            "wiki/concepts/cua-baseline.md"
        )
        XCTAssertNil(FrontendPresentation.searchResultSubtitle(relPath: "MEMORY.md"))
    }
}
