import XCTest
@testable import dream
import DreamEngine

/// FrontmatterInspector 集成测试 — 用 EditorState + 模拟 applyChanges 走 rebuildBuffer。
/// SwiftUI 视图层的 UI 交互用手动 GUI 验证，单元测试覆盖核心序列化逻辑。
@MainActor
final class FrontmatterInspectorLogicTests: XCTestCase {

    var tempDir: URL!
    var state: EditorState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("insp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        state = EditorState()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - rebuildBuffer（核心序列化）

    func testApplyChanges_preservesBodyAndReplacesFrontmatter() throws {
        let url = tempDir.appendingPathComponent("note.md")
        try """
        ---
        title: Old
        author: bio
        ---
        body content
        more body
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        XCTAssertTrue(state.buffer.contains("title: Old"))

        // 模拟 Inspector 应用：换成新 frontmatter
        let newDoc = FrontmatterParser.Document(
            fields: ["title": .string("New Title"), "tags": .stringList(["a", "b"])],
            orderedKeys: ["title", "tags"],
            body: state.buffer,
            bodyStartLine: 1
        )
        let newBuffer = rebuildBuffer(original: state.buffer, newDoc: newDoc)
        XCTAssertTrue(newBuffer.contains("title: New Title"))
        XCTAssertTrue(newBuffer.contains("tags: [a, b]"))
        XCTAssertFalse(newBuffer.contains("title: Old"))
        XCTAssertTrue(newBuffer.contains("body content"))
        XCTAssertTrue(newBuffer.contains("more body"))
    }

    func testApplyChanges_emptyDoc_keepsBodyOnly() throws {
        let url = tempDir.appendingPathComponent("note.md")
        try """
        ---
        title: Will Be Removed
        ---
        just body
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)

        let emptyDoc = FrontmatterParser.Document(
            fields: [:], orderedKeys: [], body: "", bodyStartLine: 1
        )
        let newBuffer = rebuildBuffer(original: state.buffer, newDoc: emptyDoc)
        XCTAssertFalse(newBuffer.contains("---"))
        XCTAssertFalse(newBuffer.contains("title:"))
        XCTAssertTrue(newBuffer.contains("just body"))
    }

    func testApplyChanges_addsFrontmatterToFileWithout() throws {
        let url = tempDir.appendingPathComponent("plain.md")
        try "raw body\nno frontmatter\n".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)

        let newDoc = FrontmatterParser.Document(
            fields: ["title": .string("Fresh")],
            orderedKeys: ["title"],
            body: "",
            bodyStartLine: 1
        )
        let newBuffer = rebuildBuffer(original: state.buffer, newDoc: newDoc)
        XCTAssertTrue(newBuffer.hasPrefix("---\n"))
        XCTAssertTrue(newBuffer.contains("title: Fresh"))
        XCTAssertTrue(newBuffer.contains("raw body"))
    }

    func testApplyChanges_roundTrip() throws {
        let url = tempDir.appendingPathComponent("rt.md")
        let original = """
        ---
        title: First
        count: 5
        tags: [x, y]
        ---
        body
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)

        let parsed = FrontmatterParser().parse(state.buffer)
        let rebuilt = rebuildBuffer(original: state.buffer, newDoc: parsed)
        let reparsed = FrontmatterParser().parse(rebuilt)
        XCTAssertEqual(reparsed.fields["title"], .string("First"))
        XCTAssertEqual(reparsed.fields["count"], .number(5))
        XCTAssertEqual(reparsed.fields["tags"], .stringList(["x", "y"]))
        XCTAssertEqual(reparsed.body.trimmingCharacters(in: .whitespacesAndNewlines), "body")
    }

    func testApplyChanges_preservesNestedObject() throws {
        let url = tempDir.appendingPathComponent("nested.md")
        try """
        ---
        source:
          file: raw/a.md
          line: 12
        ---
        body
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)

        let parsed = FrontmatterParser().parse(state.buffer)
        let rebuilt = rebuildBuffer(original: state.buffer, newDoc: parsed)
        let reparsed = FrontmatterParser().parse(rebuilt)
        if case .object(let inner) = reparsed.fields["source"] {
            XCTAssertEqual(inner["file"], .string("raw/a.md"))
            XCTAssertEqual(inner["line"], .number(12))
        } else {
            XCTFail("nested object should round-trip")
        }
    }

    // MARK: - rebuildBuffer helper（与 Inspector 同算法）
    // 这把 Inspector 的算法也独立可测，验证 Inspector 和 EditorState 兼容

    private func rebuildBuffer(original: String, newDoc: FrontmatterParser.Document) -> String {
        let lines = original.components(separatedBy: "\n")
        var bodyStartLine = 1
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    bodyStartLine = i + 2
                    break
                }
            }
        }
        let body = lines.dropFirst(bodyStartLine - 1).joined(separator: "\n")
        if newDoc.orderedKeys.isEmpty {
            return body
        }
        let front = FrontmatterParser.render(newDoc)
        let separator = body.isEmpty ? "" : "\n"
        let bodyStripped = body.hasPrefix("\n") ? String(body.dropFirst()) : body
        return "---\n\(front)\n---\n\(bodyStripped)\(separator)"
    }
}
