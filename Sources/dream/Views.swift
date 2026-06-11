import SwiftUI
import AppKit
import DreamEngine

// MARK: - MainView（3 栏 NavigationSplitView）

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VaultBrowser()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } content: {
            EditorPane()
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            DreamPanel()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 500)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(model.vaultRoot.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

// MARK: - VaultBrowser（左栏：文件树）

struct VaultBrowser: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedFile) {
            Section("raw/  (\(model.status.rawCandidateCount) 候选)") {
                ForEach(rawFiles(), id: \.self) { url in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(url as URL?)
                }
            }
            Section("wiki/concepts/") {
                ForEach(wikiConceptFiles(), id: \.self) { url in
                    HStack {
                        Image(systemName: "link")
                            .foregroundColor(.accentColor)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                    }
                    .tag(url as URL?)
                }
            }
            Section("wiki/archive/") {
                ForEach(wikiArchiveFiles(), id: \.self) { url in
                    HStack {
                        Image(systemName: "archivebox")
                            .foregroundColor(.gray)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                    }
                    .tag(url as URL?)
                }
            }
            Section("top-level") {
                rowIfExists("MEMORY.md", system: "brain")
                rowIfExists(".dream/ledger.json", system: "list.bullet.rectangle")
                rowIfExists(".dream/processed.json", system: "checkmark.seal")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func rowIfExists(_ rel: String, system: String) -> some View {
        let url = model.vaultRoot.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: url.path) {
            HStack {
                Image(systemName: system).foregroundColor(.secondary)
                Text(rel).lineLimit(1).truncationMode(.middle)
            }
            .tag(url as URL?)
        }
    }

    private func rawFiles() -> [URL] {
        let dir = model.vaultRoot.appendingPathComponent("raw")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
    private func wikiConceptFiles() -> [URL] {
        let dir = model.vaultRoot.appendingPathComponent("wiki/concepts")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
    private func wikiArchiveFiles() -> [URL] {
        let dir = model.vaultRoot.appendingPathComponent("wiki/archive")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
}

// MARK: - EditorPane（中栏：选中文件内容）

struct EditorPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let url = model.selectedFile {
                content(for: url)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        let isReadOnly = isRawFile(url)
        VStack(spacing: 0) {
            // header
            HStack {
                Image(systemName: isReadOnly ? "lock.fill" : "pencil")
                    .foregroundColor(isReadOnly ? .orange : .accentColor)
                Text(url.lastPathComponent)
                    .font(.headline)
                Spacer()
                if isReadOnly {
                    Text("READ-ONLY (raw/ 永远不被 dream 改)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }
                Button("Save") { saveContent(for: url) }
                    .disabled(isReadOnly || !model.textEditorDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(8)
            .background(.bar)

            // body
            if isReadOnly {
                ScrollView {
                    Text(model.textEditorContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            } else {
                TextEditor(text: $model.textEditorContent)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: model.textEditorContent) { _ in
                        model.textEditorDirty = true
                    }
                    .padding(4)
            }
        }
        .onAppear { loadContent(from: url) }
        .onChange(of: url) { _ in loadContent(from: url) }
    }

    private func isRawFile(_ url: URL) -> Bool {
        url.path.contains("/raw/")
    }

    private func loadContent(from url: URL) {
        model.textEditorContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        model.textEditorDirty = false
    }

    private func saveContent(for url: URL) {
        do {
            try model.textEditorContent.write(to: url, atomically: true, encoding: .utf8)
            model.textEditorDirty = false
        } catch {
            model.lastError = "保存失败: \(error)"
        }
    }
}

// MARK: - DreamPanel（右栏：dream 控制台 + 最近 report）

struct DreamPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header with action buttons
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "moon.stars.fill").foregroundColor(.accentColor)
                    Text("Dream").font(.headline)
                    Spacer()
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(spacing: 6) {
                    Button {
                        Task { await model.runDream() }
                    } label: {
                        Label("Run Dream", systemImage: "play.fill")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.isRunning)
                    Button(role: .destructive) {
                        model.rollback()
                    } label: {
                        Label("Rollback", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isRunning)
                    Spacer()
                    Button {
                        model.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh status")
                }
            }
            .padding(10)
            .background(.bar)

            Divider()

            // status block
            statusBlock
                .padding(10)

            Divider()

            // last report (markdown plain text) OR log
            TabView {
                reportTab
                    .tabItem { Label("Report", systemImage: "doc.plaintext") }
                logTab
                    .tabItem { Label("Log", systemImage: "text.alignleft") }
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.subheadline).bold()
            row("raw 候选", value: "\(model.status.rawCandidateCount)")
            row("ledger 总数", value: "\(model.status.totalMemories)",
                detail: "durable \(model.status.durableCount) / candidate \(model.status.candidateCount) / archived \(model.status.archivedCount)")
            row("待裁决", value: "\(model.status.withContradictsCount)")
            if let r = model.lastOutcome {
                Divider().padding(.vertical, 4)
                Text("Last Run").font(.subheadline).bold()
                row("gathered", value: "\(r.gatheredCount)")
                row("accepted", value: "\(r.acceptedCount)")
                row("archived", value: "\(r.archivedCount)")
                row("needs review", value: "\(r.needsReviewCount)")
                row("committed", value: r.committed ? "✓" : "—")
            }
            if let err = model.lastError {
                Text("⚠ \(err)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func row(_ name: String, value: String, detail: String? = nil) -> some View {
        HStack {
            Text(name).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
            if let d = detail {
                Text("(\(d))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var reportTab: some View {
        if let path = model.lastOutcome?.reportPath ?? model.status.lastReportPath,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        } else {
            VStack {
                Text("（无 dream-report）").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var logTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.logLines.count) { _ in
                if let last = model.logLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
