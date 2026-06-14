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
    let accessibilityLabel: String
    let focusToken: String?
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
        configureAccessibility(scrollView: scrollView, textView: textView)
        requestFocusIfNeeded(textView, coordinator: context.coordinator)
        // P1 修复 (缺陷报告 §3.3 P1.1): 行号 gutter
        // 老实现: 无行号. 笔记编辑器必备.
        // 新实现: 装 NSTextView 自带 NSRulerView (lineNumbers), NSTextView 自动算行数
        if let textContainer = textView.textContainer {
            let rulerView = LineNumberRulerView(textView: textView)
            rulerView.clientView = textView
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = rulerView
            textContainer.widthTracksTextView = false  // 留 gutter 宽度
        }
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

            // P0 修复 (GUI audit 2026-06-14 P0-2): NSTextView 装进 SwiftUI 包装后
            // 不会自动 becomeFirstResponder. 用户报"点编辑区后焦点仍停在 Sidebar
            // outline, 输入测试文本没有出现在界面" — 根因: textView 装好, 但
            // firstResponder 是 Sidebar outline (List 节点).
            // 修法: text 变了 (切文件) → DispatchQueue.main.async 异步抢 firstResponder.
            // 异步: 避免 view tree 还在 commit 中, 同步抢会被覆盖.
            // 只在 editable 时抢 (raw 只读, 不抢, 让 outline 留焦点).
            if isEditable {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    if window.firstResponder !== textView {
                        window.makeFirstResponder(textView)
                    }
                }
            }
        }

        // editable 可能动态变（切 raw vs wiki）
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.isSelectable = true
        }
        configureAccessibility(scrollView: scrollView, textView: textView)
        requestFocusIfNeeded(textView, coordinator: context.coordinator)
    }

    /// P2-3: Source 模式也走 attributed string — 标 wikilink (蓝色 + 下划线 + .link)
    /// P1 修复 (缺陷报告 §3.3 P1.2): 叠加 Markdown 语法高亮 (标题 / 粗体 / 行内代码 / 链接)
    private func applyAttributedText(to textView: NSTextView, from text: String) {
        var baseAttrs: [NSAttributedString.Key: Any] = [:]
        baseAttrs[.font] = textView.font
        baseAttrs[.foregroundColor] = textView.textColor ?? .labelColor
        // 1) WikiLinkExtractor 先标 wikilink (.link attribute + 蓝色)
        let attributed = WikiLinkExtractor.attributedString(from: text, baseAttrs: baseAttrs)
        // 2) 收集 wikilink 范围 (跳过 MarkdownHighlighter 的链接匹配, 避免双重着色)
        var wikilinkRanges: [NSRange] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value != nil {
                wikilinkRanges.append(range)
            }
        }
        // 3) MarkdownHighlighter 叠加 4 类高亮
        let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let highlighted = MarkdownHighlighter.highlighted(
            text,
            baseFont: baseFont,
            baseColor: textView.textColor ?? .labelColor,
            skipRanges: wikilinkRanges
        )
        // 4) 合并 wikilink attribute 到 highlighted 上 (避免丢失 .link)
        for range in wikilinkRanges {
            highlighted.addAttribute(.link, value: attributed.attribute(.link, at: range.location, effectiveRange: nil) ?? URL(string: "dreamvault://")!, range: range)
        }
        textView.textStorage?.setAttributedString(highlighted)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    private func configureAccessibility(scrollView: NSScrollView, textView: NSTextView) {
        scrollView.setAccessibilityIdentifier("DreamVaultMarkdownEditorScrollView")
        scrollView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityIdentifier("DreamVaultMarkdownEditor")
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityRole(.textArea)
    }

    private func requestFocusIfNeeded(_ textView: NSTextView, coordinator: Coordinator) {
        guard isEditable, coordinator.lastFocusToken != focusToken else { return }
        coordinator.lastFocusToken = focusToken
        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.window?.firstResponder !== textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func configureTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
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

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastSavedText: String = ""
        var lastSeenExternalText: String = ""
        var lastFocusToken: String?
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
            // 通过 NotificationCenter 把新文本传给 SwiftUI 端
            NotificationCenter.default.post(
                name: .nstextViewDidChange, object: nil,
                userInfo: ["text": newText]
            )
            // 脏检查
            let isDirty = (newText != lastSavedText)
            onDirtyChange?(isDirty)
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

// MARK: - P1 修复 (缺陷报告 §3.3 P1.1): 行号 Ruler View
/// 简易行号 gutter, 跟 NSTextView 配合显示左侧行号.
/// 实现: NSRulerView 子类, 监听 NSTextViewDidChangeNotification 重新画.
/// 比 NSTextView.lineNumberRulerView 简单直接 (后者要求 NSTextViewDelegate).
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let textColor = NSColor.tertiaryLabelColor

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 36
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange),
            name: NSText.didChangeNotification, object: textView
        )
    }
    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let text = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Self.textColor,
        ]

        // 行号从 1 开始, 逐 \n 计数
        var lineNumber = 1
        var index = 0
        // 找到 charRange 起点的行号
        while index < charRange.location {
            if text.character(at: index) == 0x0A { lineNumber += 1 }
            index += 1
        }

        // 画行号
        var glyphIndex = charRange.location
        while glyphIndex < charRange.location + charRange.length {
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: glyphIndex, length: 0), actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            let yPos = lineRect.origin.y + textView.textContainerInset.height
            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let drawRect = NSRect(
                x: ruleThickness - labelSize.width - 4,
                y: yPos,
                width: labelSize.width,
                height: lineRect.height
            )
            label.draw(in: drawRect, withAttributes: attrs)
            // 下一行
            let lineCharRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            if lineCharRange.length == 0 { break }
            glyphIndex = lineCharRange.location + lineCharRange.length
            lineNumber += 1
        }
    }
}
