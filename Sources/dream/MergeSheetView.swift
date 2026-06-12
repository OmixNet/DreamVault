import SwiftUI
import AppKit
import DreamEngine

/// P8: 双列 diff 预览 + 编辑器，让用户把两条矛盾记忆手动合并成一条。
/// 出现在 ConflictResolutionView 的 .sheet 里。
///
/// 设计要点：
///   - 左列：memory A（target）原文
///   - 右列：memory B（opponent）原文
///   - 中间 / 底部：可编辑的合并结果 textarea（@State mergedText）
///   - "Save Merge" 按钮 → 调 ConflictResolutionView 的 mergeCommit()
///   - "Cancel" 按钮 → 关 sheet
@MainActor
struct MergeSheetView: View {
    let memoryA: Memory
    let memoryB: Memory
    let vaultRoot: URL
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    /// 用户编辑中的合并结果。初始 = A 文本，用户改了就用用户的。
    @State private var mergedText: String
    /// 初始提议（基于来源数多的那条）
    private let initialSourceCount: Int

    init(memoryA: Memory,
         memoryB: Memory,
         vaultRoot: URL,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.memoryA = memoryA
        self.memoryB = memoryB
        self.vaultRoot = vaultRoot
        self.onCommit = onCommit
        self.onCancel = onCancel
        // P8 启发：合并结果默认 = source 数多的那条 + 一行 "AND:" + 另一条
        // 让用户从非空出发，避免空白提交。
        let leading: Memory
        let trailing: Memory
        if memoryA.sources.count >= memoryB.sources.count {
            leading = memoryA; trailing = memoryB
        } else {
            leading = memoryB; trailing = memoryA
        }
        let initial = """
        \(leading.text)

        AND:

        \(trailing.text)
        """
        self._mergedText = State(initialValue: initial)
        self.initialSourceCount = max(memoryA.sources.count, memoryB.sources.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundColor(.accentColor)
                Text("Merge Two Memories").font(.headline)
                Spacer()
                Text("vault: \(vaultRoot.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(.bar)

            Divider()

            // 顶部：来源信息（两边都列出）
            HStack(alignment: .top, spacing: 12) {
                sourceColumn(label: "Memory A", id: memoryA.id, sources: memoryA.sources, status: memoryA.status, color: .blue)
                Image(systemName: "arrow.left.and.right")
                    .foregroundColor(.secondary)
                    .padding(.top, 16)
                sourceColumn(label: "Memory B", id: memoryB.id, sources: memoryB.sources, status: memoryB.status, color: .purple)
            }
            .padding(12)

            Divider()

            // 中部：双列 diff 预览（read-only）
            HStack(alignment: .top, spacing: 0) {
                diffColumn(label: "A: \(memoryA.id)",
                           text: memoryA.text,
                           color: .blue)
                Divider()
                diffColumn(label: "B: \(memoryB.id)",
                           text: memoryB.text,
                           color: .purple)
            }
            .frame(minHeight: 180)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            // 底部：可编辑合并结果
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Merged Result").font(.caption).bold()
                    Spacer()
                    Text("\(mergedText.count) chars · \(mergedText.isEmpty ? "⚠ empty" : "✓ ready")")
                        .font(.caption2)
                        .foregroundColor(mergedText.isEmpty ? .red : .secondary)
                }
                TextEditor(text: $mergedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(12)

            Divider()

            // 底部：操作按钮
            HStack(spacing: 8) {
                Button {
                    mergedText = "\(memoryA.text)\n\nAND:\n\n\(memoryB.text)"
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Restore initial template (A + AND + B)")

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Merge") {
                    let trimmed = mergedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onCommit(trimmed)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func sourceColumn(label: String, id: String, sources: [SourceRef], status: MemoryStatus, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption).bold()
            }
            Text("id: \(id.prefix(12))…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text("status: \(status.rawValue)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(sources.count) source(s)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diffColumn(label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(text.count) chars")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
    }
}
