import SwiftUI
import AppKit
import DreamEngine

// MARK: - MainView（3 栏 NavigationSplitView）

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var editorState = EditorState()
    @StateObject private var gitWatcher = GitStatusWatcher()

    var body: some View {
        NavigationSplitView {
            VaultBrowser()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } content: {
            VStack(spacing: 0) {
                GitStatusBanner(currentFile: model.selectedFile, watcher: gitWatcher)
                EditorPane(state: editorState)
            }
            .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            HSplitView {
                FrontmatterInspector(state: editorState)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
                DreamPanel(editorState: editorState)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 500)
            }
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
        .onAppear {
            gitWatcher.refresh(vaultRoot: model.vaultRoot)
        }
        .onChange(of: model.selectedFile) { newFile in
            gitWatcher.refresh(vaultRoot: model.vaultRoot)
            if let f = newFile {
                gitWatcher.updateDiff(for: f, vaultRoot: model.vaultRoot)
            }
        }
        .onChange(of: editorState.buffer) { _ in
            // autosave 之后或 on-disk 变 → 重算 diff
            if let f = model.selectedFile {
                gitWatcher.updateDiff(for: f, vaultRoot: model.vaultRoot)
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
// （新版本在 EditorPane.swift；这里不再保留旧 TextEditor 实现）

// MARK: - DreamPanel（右栏：dream 控制台 + 最近 report）

struct DreamPanel: View {
    @EnvironmentObject var model: AppModel
    /// P0-1：注入 editor state，Run Dream 前先 flush buffer 到磁盘，
    /// 否则 DreamCycle 读到的可能是 autosave 之前的旧文件。
    /// EditorState 在 MainView 创建共享实例；这里可选，方便不挂 editor 的场景。
    var editorState: EditorState? = nil

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
                        // P0-1: 先 flush editor buffer，避免 DreamCycle 读到旧内容
                        if let es = editorState {
                            _ = es.flushIfDirty()
                        }
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
