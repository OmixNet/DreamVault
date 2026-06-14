import XCTest
@testable import dream

/// EditorState 状态机单元测试（autosave / dirty / flush 逻辑）。
/// UI 集成（NSTextView 桥接、split 模式）靠手动 GUI 验证，单元测试覆盖核心状态机。
@MainActor
final class EditorStateTests: XCTestCase {

    nonisolated(unsafe) var tempDir: URL!
    private var cachedState: EditorState?
    var state: EditorState {
        if let cachedState { return cachedState }
        let newState = EditorState()
        newState.autosaveDelay = 0.05  // 测试加速：50ms debounce
        cachedState = newState
        return newState
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-state-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - openFile / dirty tracking

    func testOpenFile_clearsDirty() throws {
        let url = tempDir.appendingPathComponent("test.md")
        try "initial content".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(state.openFile(url))
        XCTAssertEqual(state.buffer, "initial content")
        XCTAssertFalse(state.isDirty)
    }

    func testBufferChange_marksDirty() throws {
        let url = tempDir.appendingPathComponent("test.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        XCTAssertFalse(state.isDirty)
        // 模拟 NSTextView 改动（通过 NotificationCenter）
        NotificationCenter.default.post(
            name: .nstextViewDidChange, object: nil,
            userInfo: ["text": "modified content"]
        )
        // 给异步 dispatch 一拍时间
        let exp = expectation(description: "dirty")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(self.state.isDirty)
            XCTAssertEqual(self.state.buffer, "modified content")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - autosave debounce

    func testAutosave_writesAfterDebounce() throws {
        let url = tempDir.appendingPathComponent("autosave.md")
        try "initial".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        XCTAssertEqual(state.buffer, "initial")
        state.buffer = "user typed something"
        state.isDirty = true
        state.triggerAutosave()

        let exp = expectation(description: "autosave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(self.state.isDirty, "autosave 后应清 dirty")
            let readBack = try? String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(readBack, "user typed something")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - flushIfDirty

    func testFlushIfDirty_clearsDirtyAndPersists() throws {
        let url = tempDir.appendingPathComponent("flush.md")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        state.buffer = "new content"
        state.isDirty = true

        let result = state.flushIfDirty()
        XCTAssertTrue(result, "flushIfDirty 应成功")
        XCTAssertFalse(state.isDirty)
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "new content")
    }

    func testFlushIfDirty_noDirty_returnsTrueWithoutWriting() throws {
        let url = tempDir.appendingPathComponent("clean.md")
        try "untouched".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(state.flushIfDirty())
    }

    func testFlushIfDirty_cancelCallback_respectsUser() throws {
        let url = tempDir.appendingPathComponent("cancel.md")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        state.buffer = "new"
        state.isDirty = true

        var cancelCalled = false
        let result = state.flushIfDirty {
            cancelCalled = true
            return true  // 用户取消
        }
        XCTAssertTrue(cancelCalled)
        XCTAssertFalse(result, "用户取消应返 false")
        XCTAssertTrue(state.isDirty, "取消时保留 dirty")
    }

    // MARK: - 切文件强制 flush

    func testOpenNewFile_flushesOldFile() throws {
        let url1 = tempDir.appendingPathComponent("a.md")
        let url2 = tempDir.appendingPathComponent("b.md")
        try "a-original".write(to: url1, atomically: true, encoding: .utf8)
        try "b-original".write(to: url2, atomically: true, encoding: .utf8)

        _ = state.openFile(url1)
        state.buffer = "a-modified"
        state.isDirty = true

        // 切到 url2：必须先把 a.md 存了
        let result = state.openFile(url2)
        XCTAssertTrue(result)
        XCTAssertEqual(state.currentFile, url2)
        XCTAssertEqual(state.buffer, "b-original")
        XCTAssertFalse(state.isDirty)

        let aReadBack = try String(contentsOf: url1, encoding: .utf8)
        XCTAssertEqual(aReadBack, "a-modified", "切文件前应自动存盘")
    }

    // MARK: - saveNow 显式保存

    func testSaveNow_persistsImmediately() throws {
        let url = tempDir.appendingPathComponent("now.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        _ = state.openFile(url)
        state.buffer = "explicit save"
        state.isDirty = true
        state.saveNow()
        XCTAssertFalse(state.isDirty)
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "explicit save")
    }

    // MARK: - 模式 + raw 强制只读

    func testRaw_isAlwaysReadOnly() {
        let raw = tempDir.appendingPathComponent("raw/2026-06-11-x.md")
        XCTAssertTrue(state.isRaw(raw))
        XCTAssertFalse(state.isEditable(raw))
    }

    func testRawDetection_isVaultRelativeWhenVaultRootIsSet() throws {
        let vaultRaw = tempDir.appendingPathComponent("raw/in-vault.md")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-raw-\(UUID().uuidString)/raw/outside.md")
        try FileManager.default.createDirectory(
            at: vaultRaw.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "inside".write(to: vaultRaw, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent().deletingLastPathComponent()) }

        state.vaultRoot = tempDir

        XCTAssertTrue(state.isRaw(vaultRaw))
        XCTAssertFalse(state.isRaw(outside))
        XCTAssertFalse(state.isEditable(vaultRaw))
        XCTAssertFalse(state.isEditable(outside))
        XCTAssertFalse(state.openFile(outside), "vaultRoot 设置后不应打开 vault 外文件")
    }

    func testWiki_isEditable() {
        let wiki = tempDir.appendingPathComponent("wiki/concepts/foo.md")
        XCTAssertFalse(state.isRaw(wiki))
        XCTAssertTrue(state.isEditable(wiki))
    }

    func testRaw_split_forces_preview() {
        let raw = tempDir.appendingPathComponent("raw/x.md")
        state.mode = .split
        XCTAssertEqual(state.effectiveMode(for: raw), .preview,
                       "raw 永远不能 split 编辑；只 source 只读或 preview")
    }

    func testMemoryMd_split_allowed() {
        let mem = tempDir.appendingPathComponent("MEMORY.md")
        state.mode = .split
        XCTAssertEqual(state.effectiveMode(for: mem), .split)
    }

    // MARK: - 模式枚举

    func testEditorMode_allCases() {
        let all = EditorState.EditorMode.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(EditorState.EditorMode.source.label, "Source")
        XCTAssertEqual(EditorState.EditorMode.preview.label, "Preview")
        XCTAssertEqual(EditorState.EditorMode.split.label, "Split")
    }
}
