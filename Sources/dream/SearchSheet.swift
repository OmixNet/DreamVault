import SwiftUI
import DreamEngine

/// P3-T8: 搜索 sheet（Cmd-Shift-F 触发）
/// mdfind 包装 Spotlight，结果列表点击切 selectedFile。
public struct SearchSheet: View {
    @ObservedObject var searcher: VaultSearcher
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void
    @State private var input: String = ""

    init(searcher: VaultSearcher, model: AppModel, onDismiss: @escaping () -> Void) {
        self.searcher = searcher
        self.model = model
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search vault…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .default))
                    .onSubmit { runSearch() }
                if searcher.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()

            if searcher.results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(input.isEmpty ? "输入关键词开始搜索" : "无结果")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(searcher.results) { r in
                    Button {
                        model.selectedFile = r.path
                        onDismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.id)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(r.snippet)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            HStack {
                Text("\(searcher.results.count) results")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Powered by macOS Spotlight")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(width: 560, height: 400)
    }

    private func runSearch() {
        searcher.query = input
        searcher.search(vaultRoot: model.vaultRoot)
    }
}
