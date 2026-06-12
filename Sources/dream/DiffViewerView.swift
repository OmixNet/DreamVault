import SwiftUI
import AppKit
import DreamEngine

/// 真 diff 视图窗口：左右两栏 unified diff。
///
/// 触发点：GitStatusBanner 上的 "Open Diff" 按钮（修改 / 冲突时显示）。
/// 颜色规则：绿=added / 红=removed / 灰=context。
public struct DiffViewerView: View {
    let title: String
    let diff: DiffGenerator.Result
    let onClose: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("+\(diff.addedCount)  −\(diff.removedCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(.bar)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            // 行号
                            Text("\(idx + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 8)
                            // 前缀符号
                            Text(prefix(for: line.kind))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(color(for: line.kind))
                                .frame(width: 16, alignment: .center)
                            // 内容
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(background(for: line.kind))
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private func prefix(for kind: DiffGenerator.Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private func color(for kind: DiffGenerator.Line.Kind) -> Color {
        switch kind {
        case .added: return Color(red: 0.13, green: 0.55, blue: 0.30)
        case .removed: return Color(red: 0.75, green: 0.20, blue: 0.20)
        case .context: return .primary
        }
    }

    private func background(for kind: DiffGenerator.Line.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}
