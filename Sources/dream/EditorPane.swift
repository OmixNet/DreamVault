import SwiftUI
import AppKit
import DreamEngine

/// EditorPane（中栏：选中文件内容）
///
/// 三模式：
///   - Source  : NSTextView 全屏编辑（raw/ 只读）
///   - Preview : MarkdownRenderer 渲染视图（不可编辑，arch doc §5 防幻觉）
///   - Split   : 左 Source 右 Preview（raw/ 强制只读时 Preview-only）
///
/// autosave 走 EditorState.debounce(1.5s)；切文件/run dream/关窗前 EditorState.flushIfDirty()。
public struct EditorPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: EditorState
    @ObservedObject var markdownRenderer: MarkdownRendererHolder = .shared

    public init(state: EditorState) {
        self.state = state
    }

    public var body: some View {
        Group {
            if let url = state.currentFile {
                content(for: url)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(model.$selectedFile.compactMap { $0 }) { url in
            // 上层切换文件时：flush 旧 → load 新
            _ = state.openFile(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 关窗前 force flush
            _ = state.flushIfDirty()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            _ = state.flushIfDirty()
        }
    }

    // MARK: - 视图

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("选个文件开始看")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("左侧是 vault 文件树")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        let editable = state.isEditable(url)
        let effectiveMode = state.effectiveMode(for: url)
        VStack(spacing: 0) {
            header(url: url, editable: editable, effectiveMode: effectiveMode)
            Divider()
            editorBody(url: url, editable: editable, effectiveMode: effectiveMode)
        }
    }

    @ViewBuilder
    private func header(url: URL, editable: Bool, effectiveMode: EditorState.EditorMode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: editable ? "pencil" : "lock.fill")
                .foregroundColor(editable ? .accentColor : .orange)
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if !editable {
                Text("READ-ONLY")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            } else if state.isDirty {
                Text("• 未保存")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else {
                Text("已保存")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            modePicker(url: url, effectiveMode: effectiveMode)
            Button("Save") { state.saveNow() }
                .disabled(!editable || !state.isDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Cmd-S 显式保存")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func modePicker(url: URL, effectiveMode: EditorState.EditorMode) -> some View {
        // raw 文件只允许 source / preview，不能 split 编辑
        Picker("Mode", selection: Binding(
            get: { state.mode },
            set: { state.mode = $0 }
        )) {
            ForEach(EditorState.EditorMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
        .disabled(state.isRaw(url) && effectiveMode == .source)
        // raw 文件：Source 模式下 picker 显示 source/preview，但 Source 实际只是只读展示
    }

    @ViewBuilder
    private func editorBody(url: URL, editable: Bool, effectiveMode: EditorState.EditorMode) -> some View {
        switch effectiveMode {
        case .source:
            sourceEditor(editable: editable)
        case .preview:
            previewView
        case .split:
            HStack(spacing: 0) {
                sourceEditor(editable: editable)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                previewView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func sourceEditor(editable: Bool) -> some View {
        NSTextViewRepresentable(
            text: Binding(
                get: { state.buffer },
                set: { state.buffer = $0 }
            ),
            isEditable: editable,
            fontSize: 13,
            onCommit: { state.saveNow() },
            onDirtyChange: { dirty in state.isDirty = dirty },
            // P2-A2: Source 模式点 [[wikilink]] 跳到对应文件
            onWikilink: { url in openWikilink(url) }
        )
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Preview 不可编辑（arch doc §5 防幻觉：raw 不可被编辑器改；即使是 wiki preview 也是只读快照）
                if let attr = Optional(renderMarkdown(state.buffer)) {
                    Text(attr)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    Text("（无内容预览）")
                        .foregroundColor(.secondary)
                        .padding(12)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        // P2-A2: 拦截 dreamvault://wikilink/<id> 的点击，
        // 命中 vault 内 .md 文件就交给 AppModel 切换选中。
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "dreamvault" {
                openWikilink(url)
                return .handled
            }
            // 其他 URL（http/https/file://）走系统默认（外部浏览器 / Finder）
            return .systemAction
        })
    }

    /// 用 T0 + T2 的 MarkdownRenderer 渲染：把 NSAttributedString 桥到 SwiftUI AttributedString。
    /// NSAttributedString 上面的 .link / .font / .foregroundColor 都会带过去（macOS 12+）。
    ///
    /// P3-T6 决策：选自研 renderer 而非 SwiftUI `Text(markdown:)`。
    ///   - SwiftUI Text(markdown:) 13 不支持表格（14+ 才完整支持）
    ///   - 自研 renderer 在 T2 已经支持表格 / 图片 / wikilink
    ///   - 链接跳转走 NSAttributedString.link（cancellable 不依赖 AttributedString.link 渲染）
    ///   - macOS 13 + 自研渲染是最佳选择
    private func renderMarkdown(_ md: String) -> AttributedString {
        let ns = markdownRenderer.renderer.render(md)
        if #available(macOS 12, *) {
            return AttributedString(ns)
        }
        // 旧系统降级：纯文本（macOS 13 target 不该到这）
        return AttributedString(ns.string)
    }

    /// P2-A2: 解析 dreamvault://wikilink/<id>。
    /// 命中 vault 内 .md 文件 → 选进 editor；未命中 → stderr 提示（不弹 alert，避免 preview 噪音）。
    private func openWikilink(_ url: URL) {
        guard let resolved = WikilinkResolver.resolve(url: url, vaultRoot: model.vaultRoot) else {
            if url.scheme == "dreamvault" {
                FileHandle.standardError.write(Data(
                    "[EditorPane] wikilink \(url.absoluteString) not found in vault\n".utf8))
            }
            return
        }
        model.selectedFile = resolved
    }
}

/// 全局持有 MarkdownRenderer 实例（避免每次 render 都新建）
public final class MarkdownRendererHolder: ObservableObject {
    public static let shared = MarkdownRendererHolder()
    public let renderer = MarkdownRenderer()
    private init() {}
}
