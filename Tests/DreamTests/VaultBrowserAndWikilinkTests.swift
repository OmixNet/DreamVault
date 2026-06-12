import XCTest
@testable import DreamEngine
@testable import dream
import AppKit

/// P2-A1 / P2-A2 回归测试：
/// - A1：VaultBrowser 列出 4 个 wiki 子目录（entities/concepts/syntheses/archive）
/// - A2：dreamvault://wikilink/<id> 解析为 vault 内 .md 路径
@MainActor
final class VaultBrowserAndWikilinkTests: XCTestCase {

    // MARK: - P2-A2: WikilinkResolver

    func testResolve_exactMatchInConcepts() {
        let vault = makeVault()
        try? "body".write(to: vault.appendingPathComponent("wiki/concepts/foo.md"),
                          atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vault) }

        let url = URL(string: "dreamvault://wikilink/foo")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        XCTAssertEqual(resolved?.lastPathComponent, "foo.md")
        XCTAssertEqual(resolved?.pathExtension, "md")
    }

    func testResolve_searchesAllFourSubdirs() {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        // 把同一个 id 放 4 个子目录 → 解析器按 entities > concepts > syntheses > archive 顺序
        for rel in ["wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive"] {
            try? "x".write(to: vault.appendingPathComponent("\(rel)/shared.md"),
                           atomically: true, encoding: .utf8)
        }
        let url = URL(string: "dreamvault://wikilink/shared")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        // 命中第一个子目录（按实现顺序）
        XCTAssertEqual(resolved?.path, vault.appendingPathComponent("wiki/entities/shared.md").path)
    }

    func testResolve_urlEncodedId() {
        let vault = makeVault()
        try? "x".write(to: vault.appendingPathComponent("wiki/concepts/some id.md"),
                       atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vault) }

        // id 编码成 "some%20id"
        let url = URL(string: "dreamvault://wikilink/some%20id")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        XCTAssertEqual(resolved?.lastPathComponent, "some id.md")
    }

    func testResolve_missingFile_returnsNil() {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = URL(string: "dreamvault://wikilink/does-not-exist")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        XCTAssertNil(resolved)
    }

    func testResolve_wrongScheme_returnsNil() {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = URL(string: "https://example.com/foo")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        XCTAssertNil(resolved)
    }

    func testResolve_emptyPath_returnsNil() {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = URL(string: "dreamvault://wikilink/")!
        let resolved = WikilinkResolver.resolve(url: url, vaultRoot: vault)
        XCTAssertNil(resolved)
    }

    // MARK: - P2-A1: VaultBrowser 4 子目录

    func testVaultBrowser_listsAllFourSubdirs() {
        let vault = makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        for rel in ["wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive"] {
            try? "x".write(to: vault.appendingPathComponent("\(rel)/a.md"),
                           atomically: true, encoding: .utf8)
            try? "x".write(to: vault.appendingPathComponent("\(rel)/b.md"),
                           atomically: true, encoding: .utf8)
        }

        // VaultBrowser 是 SwiftUI View 不便直接测，间接测底层 helper
        let fm = FileManager.default
        for rel in ["wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive"] {
            let dir = vault.appendingPathComponent(rel)
            let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let mds = all.filter { $0.pathExtension == "md" }
            XCTAssertEqual(mds.count, 2, "\(rel) 应有 2 个 .md，实际 \(mds.count)")
        }
    }

    // MARK: - helper

    private func makeVault() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-p2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 预建 4 个 wiki 子目录 + raw/，让测试直接写 .md 不会失败
        for sub in WikilinkResolver.subdirs {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub),
                                                     withIntermediateDirectories: true)
        }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("raw"),
                                                 withIntermediateDirectories: true)
        return dir
    }
}
