import SwiftUI
import DreamEngine

/// P3-T8: 搜索 sheet（Cmd-Shift-F 触发）
/// mdfind 包装 Spotlight，结果列表点击切 selectedFile。
public struct SearchSheet: View {
    @ObservedObject var searcher: VaultSearcher
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void
    @State private var input: String = ""

    init(searcher: VaultSearcher, model: AppModel, initialQuery: String = "", onDismiss: @escaping () -> Void) {
        self.searcher = searcher
        self.model = model
        self._input = State(initialValue: initialQuery)
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
                Button {
                    runSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
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
                        // P9c-P0-2: 搜索结果命中若是某条 memory 的 wiki 页，强化一下
                        // （EditorPane 的 .onReceive 也会触发 wikiOpen，但 searchClick 是独立 source，
                        //  两者同日不互防抖）
                        if let id = Reinforcer.memoryID(forVaultRelPath: r.id) {
                            _ = model.reinforcer.reinforce(memoryID: id, source: .searchClick)
                        }
                        onDismiss()
                    } label: {
                        let body = try? String(contentsOf: r.path, encoding: .utf8)
                        let title = FrontendPresentation.searchResultTitle(relPath: r.id, body: body)
                        let subtitle = FrontendPresentation.searchResultSubtitle(relPath: r.id)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(title)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let subtitle, subtitle != title {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Text(r.snippet)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
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
        .onAppear {
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runSearch()
            }
        }
    }

    private func runSearch() {
        searcher.query = input
        searcher.search(vaultRoot: model.vaultRoot)
    }
}
