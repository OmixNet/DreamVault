import SwiftUI
import AppKit
import DreamEngine

/// NSTextView 桥接 SwiftUI —— 真正的 macOS 文本编辑器。
///
/// 比 SwiftUI `TextEditor` 强的地方：
///   - 大文件（100k+ 行）流畅（lazy layout / NSTextLayoutManager）
///   - 原生 undo/redo（NSUndoManager）
///   - 完整 key binding（Cmd-A / Cmd-L / Option-Arrow / 缩进等）
///   - 保留滚动位置（跨 reload）
///   - 等宽字体 + syntax 风格
///   - Find/Replace 走 macOS 系统的 Find Bar
///
/// 不做的（保持轻量）：
///   - 语法高亮（留给后面 T2/T3）
///   - 自动补全（留给 T2 wikilink +++)
    public struct NSTextViewRepresentable: NSViewRepresentable {

    @Binding var text: String
    let isEditable: Bool
    let fontSize: CGFloat
    let onCommit: () -> Void        // 切文件/run dream/关窗前调用（autosave 也走这条）
    let onDirtyChange: (Bool) -> Void  // 通知 SwiftUI dirty 状态变化
    /// P2-A2: Source 模式下点 wikilink（dreamvault://wikilink/<id>）时调用。
    /// 默认 nil 表示不拦截，走 NSTextView 默认行为（NSWorkspace 打开）。
    /// Pane 设了它就把 vault 内的 wikilink 解析为文件并切换选中。
    var onWikilink: ((URL) -> Void)? = nil

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        configureTextView(textView, coordinator: context.coordinator)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.lastSavedText = text
        applyAttributedText(to: textView, from: text)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 只在外部真的改了 text（切文件/loadContent）才重设 string —— 避免撤销用户输入
        if text != context.coordinator.lastSeenExternalText {
            let savedSelection = textView.selectedRange
            let savedScroll = scrollView.contentView.bounds.origin
            applyAttributedText(to: textView, from: text)
            textView.selectedRange = savedSelection
            scrollView.contentView.scroll(to: savedScroll)
            context.coordinator.lastSeenExternalText = text
            context.coordinator.lastSavedText = text
            textView.undoManager?.removeAllActions()
        }

        // editable 可能动态变（切 raw vs wiki）
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.isSelectable = true
        }
    }

    /// P2-3: Source 模式也走 attributed string — 标 wikilink (蓝色 + 下划线 + .link)
    private func applyAttributedText(to textView: NSTextView, from text: String) {
        var baseAttrs: [NSAttributedString.Key: Any] = [:]
        baseAttrs[.font] = textView.font
        baseAttrs[.foregroundColor] = textView.textColor ?? .labelColor
        let attributed = WikiLinkExtractor.attributedString(from: text, baseAttrs: baseAttrs)
        textView.textStorage?.setAttributedString(attributed)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    private func configureTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true           // Cmd-F 调出系统 Find Bar
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false  // 笔记里引号很关键
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = true
        textView.usesFontPanel = false

        // 等宽字体
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // 自动换行（off = 长行不折行，水平滚动；与 monospace 配合更接近 IDE 体验）
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.lineBreakMode = .byClipping

        // 颜色
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]

        // 委托
        textView.delegate = coordinator

        // Coordinator 拿到 closure 引用
        coordinator.textView = textView
        coordinator.onCommit = onCommit
        coordinator.onDirtyChange = onDirtyChange
        coordinator.onWikilink = onWikilink
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastSavedText: String = ""
        var lastSeenExternalText: String = ""
        var onCommit: (() -> Void)?
        var onDirtyChange: ((Bool) -> Void)?
        var onWikilink: ((URL) -> Void)?

        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                            replacementString: String?) -> Bool {
            // 记录光标位置 / 滚动位置跨 updateNSView 调用
            return true
        }

        public func textViewDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            // 通知 SwiftUI（text 双向绑定）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 通过 NotificationCenter 把新文本传给 SwiftUI 端
                NotificationCenter.default.post(
                    name: .nstextViewDidChange, object: nil,
                    userInfo: ["text": newText]
                )
                // 脏检查
                let isDirty = (newText != self.lastSavedText)
                self.onDirtyChange?(isDirty)
            }
        }

        // P2-A2: NSTextView 点 .link attribute 触发。dreamvault:// 拦截处理；
        // 其他 URL（http/https/file）回退 NSTextView 默认（NSWorkspace 打开）。
        public func textView(_ textView: NSTextView, clickedOnLink link: Any,
                             at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL { url = u }
            else if let s = link as? String { url = URL(string: s) }
            else { return false }
            guard let u = url else { return false }
            if u.scheme == "dreamvault", let handler = onWikilink {
                handler(u)
                return true  // 已处理，不要走 NSWorkspace
            }
            return false  // 让 NSTextView 走默认（NSWorkspace.shared.open）
        }
    }
}

extension Notification.Name {
    /// NSTextView 编辑后发出；EditorPane 监听这个把 text 同步回 @State。
    /// 用 Notification 而非 @Binding 双向同步是因为 @Binding 在 NSViewRepresentable
    /// 里更新会触发 updateNSView，干扰 NSTextView 内部 undoManager 的 selectedRange。
    public static let nstextViewDidChange = Notification.Name("DreamVault.nstextViewDidChange")
}
