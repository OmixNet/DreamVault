import SwiftUI
import AppKit
import DreamEngine

/// Frontmatter Inspector 面板（右侧第 4 栏，可选）。
///
/// 设计：
///   - 解析当前 buffer 的 frontmatter（用 T0 的 FrontmatterParser）
///   - 按插入顺序展示 key-value 列表（arch doc 不强制 schema）
///   - 每行可编辑；编辑后点 "Apply" 写回 buffer（不立即覆盖 disk，autosave 走原路径）
///   - 增 / 删 / 改 三个操作都支持
///   - raw 文件禁用 Inspector（arch doc 0.1 raw 永远只读）
///
/// 布局：左标题栏 + key-value 列表 + 底部 + 键 - 删键
public struct FrontmatterInspector: View {
    @ObservedObject var state: EditorState
    @State private var pendingDoc: FrontmatterParser.Document?
    @State private var hasUnappliedChanges: Bool = false

    public var body: some View {
        Group {
            if let url = state.currentFile {
                if state.isRaw(url) {
                    disabledForRaw
                } else {
                    editor(url: url)
                }
            } else {
                noFile
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: state.buffer) { _ in
            // buffer 改了（切文件/外部 autosave）→ 重新解析 pendingDoc
            reparseBuffer()
        }
        .onChange(of: state.currentFile) { _ in
            reparseBuffer()
        }
    }

    // MARK: - 视图

    private var noFile: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.title)
                .foregroundColor(.secondary)
            Text("Frontmatter Inspector")
                .font(.headline)
            Text("打开非 raw 文件后可编辑 frontmatter")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disabledForRaw: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.title)
                .foregroundColor(.orange)
            Text("raw/ 文件不可编辑")
                .font(.headline)
            Text("arch doc 0.1: raw 永远只读")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func editor(url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle.fill")
                    .foregroundColor(.accentColor)
                Text("Frontmatter")
                    .font(.headline)
                Spacer()
                if hasUnappliedChanges {
                    Button("Apply") { applyChanges(url: url) }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Discard") {
                        reparseBuffer()
                        hasUnappliedChanges = false
                    }
                }
            }
            .padding(8)
            .background(.bar)

            if let doc = pendingDoc, !doc.isEmpty {
                List {
                    ForEach(doc.orderedKeys, id: \.self) { key in
                        if let value = doc.fields[key] {
                            fieldRow(key: key, value: value)
                        }
                    }
                }
                .listStyle(.inset)

                addFieldBar(doc: doc)
            } else {
                Spacer()
                Text("（无 frontmatter）")
                    .foregroundColor(.secondary)
                Spacer()
                addFieldBar(doc: FrontmatterParser.Document(fields: [:], orderedKeys: [],
                                                          body: state.buffer, bodyStartLine: 1))
            }

            Divider()
            HStack {
                Text("显示标题：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(displayTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func fieldRow(key: String, value: FrontmatterParser.Value) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key)
                    .font(.system(.body, design: .monospaced).bold())
                Spacer()
                Button {
                    deleteKey(key)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此字段")
            }
            // 值编辑
            if isEditing(key: key) {
                HStack {
                    TextField("value", text: $editingValue, onCommit: commitEdit)
                        .textFieldStyle(.roundedBorder)
                    Button("Done") { commitEdit() }
                }
            } else {
                Text(valueDisplay(value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .onTapGesture { startEdit(key: key, value: value) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func addFieldBar(doc: FrontmatterParser.Document) -> some View {
        HStack {
            TextField("add key", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            TextField("value", text: $newValue)
                .textFieldStyle(.roundedBorder)
            Button {
                addField()
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(newKey.isEmpty)
        }
        .padding(8)
    }

    // MARK: - 状态

    @State private var editingKey: String? = nil
    @State private var editingValue: String = ""
    @State private var newKey: String = ""
    @State private var newValue: String = ""

    private func isEditing(key: String) -> Bool { editingKey == key }

    private func startEdit(key: String, value: FrontmatterParser.Value) {
        editingKey = key
        editingValue = value.asString
    }

    private func commitEdit() {
        guard let key = editingKey, var doc = pendingDoc else { return }
        doc.fields[key] = .string(editingValue)
        pendingDoc = doc
        hasUnappliedChanges = true
        editingKey = nil
        editingValue = ""
    }

    private func deleteKey(_ key: String) {
        guard var doc = pendingDoc else { return }
        doc.fields.removeValue(forKey: key)
        doc.orderedKeys.removeAll { $0 == key }
        pendingDoc = doc
        hasUnappliedChanges = true
    }

    private func addField() {
        guard !newKey.isEmpty, var doc = pendingDoc else { return }
        // 简单推断：数字、bool 直接转，否则 string
        let v: FrontmatterParser.Value
        if let n = Int(newValue) {
            v = .number(Double(n))
        } else if newValue == "true" {
            v = .bool(true)
        } else if newValue == "false" {
            v = .bool(false)
        } else if newValue.hasPrefix("[") && newValue.hasSuffix("]") {
            v = .stringList(newValue.dropFirst().dropLast()
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            v = .string(newValue)
        }
        if doc.fields[newKey] == nil {
            doc.orderedKeys.append(newKey)
        }
        doc.fields[newKey] = v
        pendingDoc = doc
        hasUnappliedChanges = true
        newKey = ""
        newValue = ""
    }

    private func reparseBuffer() {
        let doc = FrontmatterParser().parse(state.buffer)
        pendingDoc = doc
        hasUnappliedChanges = false
    }

    private func applyChanges(url: URL) {
        guard let doc = pendingDoc else { return }
        // 序列化 frontmatter → 拼到 buffer 头（替换原 frontmatter 区）
        let newBuffer = rebuildBuffer(original: state.buffer, newDoc: doc)
        state.buffer = newBuffer
        state.isDirty = true
        hasUnappliedChanges = false
        // 触发 autosave
        NotificationCenter.default.post(
            name: .nstextViewDidChange, object: nil,
            userInfo: ["text": newBuffer]
        )
    }

    /// 用新 frontmatter doc 替换原 buffer 的 frontmatter 区，保留 body。
    private func rebuildBuffer(original: String, newDoc: FrontmatterParser.Document) -> String {
        let lines = original.components(separatedBy: "\n")
        var bodyStartLine = 1  // 1-based
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            // 找闭合 ---
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    bodyStartLine = i + 2
                    break
                }
            }
        }
        let body = lines.dropFirst(bodyStartLine - 1).joined(separator: "\n")
        if newDoc.orderedKeys.isEmpty {
            // 无 frontmatter → 只 body
            return body
        }
        let front = FrontmatterParser.render(newDoc)
        // body 前面保证有 \n
        let separator = body.isEmpty ? "" : "\n"
        return "---\n\(front)\n---\n\(body.hasPrefix("\n") ? String(body.dropFirst()) : body)\(separator)"
    }

    private func valueDisplay(_ v: FrontmatterParser.Value) -> String {
        switch v {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .stringList(let xs): return "[" + xs.joined(separator: ", ") + "]"
        case .intList(let xs): return "[" + xs.map(String.init).joined(separator: ", ") + "]"
        case .object: return "{...}"
        }
    }

    private var displayTitle: String {
        guard let url = state.currentFile else { return "—" }
        let rel = (url.path as NSString).lastPathComponent  // 简化（不走 vault 根）
        let body = state.buffer
        return TitleResolver.displayTitle(relPath: rel,
                                          frontmatter: pendingDoc,
                                          body: body)
    }
}
