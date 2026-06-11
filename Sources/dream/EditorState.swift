import Foundation
import SwiftUI
import Combine

/// EditorPane 的状态机：管理当前文件、autosave debounce、脏检查、强制 flush。
///
/// 设计：纯 Swift 对象，SwiftUI 视图订阅它的 @Published。
/// autosave 通过 Combine 的 `debounce` 实现（标准 SwiftUI 模式）。
@MainActor
public final class EditorState: ObservableObject {

    /// 当前打开的文件（nil = 没选）
    @Published public var currentFile: URL? = nil
    /// 当前 buffer 内容。
    /// 写入时会自动比较 lastSavedSnapshot 重算 isDirty，
    /// 这样不仅是 NSTextView 路径（macOS Text Replacement / 外部 macro / 测试设值）
    /// 都能正确标脏。
    @Published public var buffer: String = "" {
        didSet {
            if oldValue != buffer {
                isDirty = (buffer != lastSavedSnapshot)
            }
        }
    }
    /// 是否有未保存修改
    @Published public var isDirty: Bool = false
    /// 模式：source / preview / split
    @Published public var mode: EditorMode = .source
    /// 1.5s 自动保存（可配）。**改值会重建 debounce pipeline**（不重启 app 调小/调大）。
    public var autosaveDelay: TimeInterval = 1.5 {
        didSet {
            guard oldValue != autosaveDelay else { return }
            debounceCancellable?.cancel()
            installAutosavePipeline()
        }
    }

    private var lastSavedSnapshot: String = ""
    private var debounceSubject = PassthroughSubject<String, Never>()

    /// 测试用：暴露 lastSavedSnapshot 当前值
    public var lastSavedSnapshotMirror: String { lastSavedSnapshot }
    private let fileManager = FileManager.default

    public init() {
        installAutosavePipeline()
    }

    private func installAutosavePipeline() {
        // 监听 NSTextView 改动 → 触发 debounce autosave
        // NSTextView 路径里 buffer 已经被 textViewDidChange 同步更新过，
        // 所以这里直接 scheduleAutosave 即可（不需要重新算 isDirty）。
        ncObserver = NotificationCenter.default.addObserver(
            forName: .nstextViewDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let text = note.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                self.buffer = text
                self.isDirty = (text != self.lastSavedSnapshot)
                self.scheduleAutosave()
            }
        }

        // debounce → flush pipeline
        debounceCancellable = debounceSubject
            .debounce(for: .seconds(autosaveDelay), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.flushPending()
                }
            }
    }

    private var ncObserver: NSObjectProtocol?
    private var debounceCancellable: AnyCancellable?

    // MARK: - 文件切换

    /// 打开新文件前**必须**调用 flushIfDirty —— 这是上游（切文件按钮/run dream/关窗）
    /// 调用的入口。返回 true 表示成功保存或没脏数据；false 表示用户取消或保存失败。
    @discardableResult
    public func openFile(_ url: URL) -> Bool {
        guard flushIfDirty() else { return false }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            self.currentFile = url
            self.buffer = content
            self.lastSavedSnapshot = content
            self.isDirty = false
            return true
        } catch {
            return false
        }
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        debounceSubject.send(buffer)
    }

    /// 测试 / 外部触发 autosave 用的 public 入口
    public func triggerAutosave() {
        scheduleAutosave()
    }

    /// autosave 触发后调用：写回磁盘（不弹任何 UI）
    private func flushPending() {
        guard isDirty, let file = currentFile else { return }
        let toWrite = buffer
        do {
            try toWrite.write(to: file, atomically: true, encoding: .utf8)
            lastSavedSnapshot = toWrite
            isDirty = false
        } catch {
            FileHandle.standardError.write(Data(
                "[EditorState] autosave 写盘失败：\(error.localizedDescription)\n".utf8))
        }
    }

    /// 强制立即 flush。**任何切换上下文前**必须调（切文件、跑 dream、关窗）。
    /// 用户脏了未保存 → 如果有 cancel 回调就弹确认；否则直接 autosave。
    /// - Returns: true = 成功保存（或没脏）；false = 用户取消
    @discardableResult
    public func flushIfDirty(cancel: (() -> Bool)? = nil) -> Bool {
        guard isDirty else { return true }
        if let cancel, cancel() {
            return false  // 用户取消
        }
        // 写回
        do {
            if let file = currentFile {
                try buffer.write(to: file, atomically: true, encoding: .utf8)
                lastSavedSnapshot = buffer
                isDirty = false
            }
        } catch {
            return false
        }
        return true
    }

    // MARK: - 显式保存（Cmd-S）

    public func saveNow() {
        flushPending()
    }

    // MARK: - 模式

    public enum EditorMode: String, CaseIterable, Identifiable {
        case source, preview, split
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .source: return "Source"
            case .preview: return "Preview"
            case .split: return "Split"
            }
        }
    }

    /// raw/ 下的文件强制只 source/preview，split 也只读（防止用户在 Split 半边误编辑）
    public func effectiveMode(for url: URL?) -> EditorMode {
        guard let url, isRaw(url) else { return mode }
        return mode == .source ? .source : .preview
    }

    public func isRaw(_ url: URL) -> Bool {
        url.path.contains("/raw/")
    }

    /// raw 文件是否可编辑（永远 false — arch doc 0.1 raw 永远只读）
    public func isEditable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !isRaw(url)
    }
}
