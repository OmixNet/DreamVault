// P2-3: Insert Wikilink 输入框 (SwiftUI sheet)
import SwiftUI
import AppKit
import DreamEngine

@MainActor
public struct InsertWikilinkView: View {
    public let onCommit: (String, String?) -> Void  // (target, alias?) → void
    public let onCancel: () -> Void
    @State private var target: String = ""
    @State private var alias: String = ""
    @FocusState private var targetFocused: Bool

    public init(onCommit: @escaping (String, String?) -> Void,
                onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Wikilink")
                .font(.title3).bold()
            Text("Target 是要跳转的页名 (e.g. \"swiftui\" 或 \"raw/notes.md\")。Alias 是显示文字 (留空用 target)。")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Target")
                    .font(.caption).bold()
                TextField("e.g. swiftui", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .focused($targetFocused)
                    .onSubmit { commit() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Alias (optional)")
                    .font(.caption).bold()
                TextField("e.g. SwiftUI 笔记", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
            }
            // 预览
            if !target.isEmpty {
                Text("Preview: \(WikiLinkExtractor.insertionString(target: target, alias: alias.isEmpty ? nil : alias))")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380, height: 280)
        .onAppear { targetFocused = true }
    }

    private func commit() {
        guard !target.isEmpty else { return }
        onCommit(target, alias.isEmpty ? nil : alias)
    }
}
