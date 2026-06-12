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
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Insert Wikilink")
                .font(AppFont.title3)
            Text("Target 是要跳转的页名 (e.g. \"swiftui\" 或 \"raw/notes.md\")。Alias 是显示文字 (留空用 target)。")
                .font(AppFont.caption)
                .foregroundColor(AppColor.textSecondary)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Target")
                    .font(AppFont.caption).bold()
                TextField("e.g. swiftui", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .focused($targetFocused)
                    .onSubmit { commit() }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Alias (optional)")
                    .font(AppFont.caption).bold()
                TextField("e.g. SwiftUI 笔记", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
            }
            // 预览
            if !target.isEmpty {
                Text("Preview: \(WikiLinkExtractor.insertionString(target: target, alias: alias.isEmpty ? nil : alias))")
                    .font(AppFont.monoSmall)
                    .padding(Spacing.xs + 2)
                    .background(AppColor.surface)
                    .cornerRadius(Radius.sm)
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
        .padding(Spacing.lg)
        .frame(width: 380, height: 280)
        .onAppear { targetFocused = true }
    }

    private func commit() {
        guard !target.isEmpty else { return }
        onCommit(target, alias.isEmpty ? nil : alias)
    }
}
