import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DreamEngine

// MARK: - MainView（3 栏 NavigationSplitView）

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var editorState = EditorState()
    @StateObject private var gitWatcher = GitStatusWatcher()
    @StateObject private var searcher = VaultSearcher()
    @StateObject private var updateChecker = UpdateChecker()
    @SceneStorage("DreamVault.MainView.showInspector") private var showInspector: Bool = true
    @SceneStorage("DreamVault.MainView.searchText") private var vaultSearchText: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// P7-T1: 首次启动弹 welcome sheet
    @State private var showWelcome: Bool = false
    /// P2-2: 弹 Knowledge Graph 窗口
    @State private var showGraph: Bool = false
    /// P2-3: 弹 Insert Wikilink 输入框
    @State private var showInsertWikilink: Bool = false
    /// P2-4: 偶然唤回 banner
    @State private var serendipityPick: SerendipityPick? = nil
    @State private var serendipityDismissed: Bool = false

    /// P3-C1: 把 model 和 editorState 写进 FocusedValues，菜单 command 才能读
    var body: some View {
        content
            .focusedSceneValue(\.appModel, model)
            .focusedSceneValue(\.editorState, editorState)
    }

    @State private var showSearch = false

    @ViewBuilder
    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VaultBrowser()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } content: {
            VStack(spacing: 0) {
                GitStatusBanner(currentFile: model.selectedFile, watcher: gitWatcher)
                EditorPane(state: editorState)
            }
            .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            if showInspector {
                HSplitView {
                    FrontmatterInspector(state: editorState)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
                    DreamPanel(editorState: editorState)
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                }
            } else {
                InspectorHiddenPlaceholder {
                    showInspector = true
                    columnVisibility = .all
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VaultTitleView(
                    title: FrontendPresentation.vaultDisplayName(path: model.vaultRoot.path),
                    subtitle: FrontendPresentation.vaultSubtitle(path: model.vaultRoot.path)
                )
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    runDreamFromToolbar()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("Run Dream (Cmd-D)")
                .disabled(model.isRunning)

                Button {
                    NotificationCenter.default.post(name: .dreamVaultImportToRaw, object: nil)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import files to raw/ (Cmd-I)")

                Button {
                    showGraph = true
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .help("Open Knowledge Graph")

                Button {
                    openSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search vault (Cmd-Shift-F)")

                Button {
                    toggleInspector()
                } label: {
                    Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                }
                .help(showInspector ? "Hide inspector" : "Show inspector")
            }
        }
        .searchable(text: $vaultSearchText, prompt: "Search Vault")
        .onSubmit(of: .search) {
            openSearch(query: vaultSearchText)
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(searcher: searcher, model: model, initialQuery: vaultSearchText) {
                showSearch = false
            }
        }
        // P2-2: Knowledge Graph 弹窗
        .sheet(isPresented: $showGraph) {
            GraphWindow(
                graph: KnowledgeGraph(memories: model.ledger.memories),
                memories: model.ledger.memories,
                onTap: { mem in
                    model.openMemory(mem)
                    showGraph = false
                },
                onDismiss: { showGraph = false }
            )
        }
        // P2-3: Insert Wikilink 输入框
        .sheet(isPresented: $showInsertWikilink) {
            InsertWikilinkView(
                onCommit: { target, alias in
                    let ins = WikiLinkExtractor.insertionString(target: target, alias: alias)
                    // 简化: 追加到 buffer 末尾 + 留 spacing (光标位置让用户自己控制)
                    if !editorState.buffer.isEmpty, !editorState.buffer.hasSuffix("\n") {
                        editorState.buffer += "\n"
                    }
                    editorState.buffer += ins
                    showInsertWikilink = false
                },
                onCancel: { showInsertWikilink = false }
            )
        }
        // P6-T3: 启动后 3s 静默检查更新（不打扰）
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            updateChecker.check()
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let info = updateChecker.update, info.isUpdateAvailable {
                    UpdateBanner(info: info) {
                        updateChecker.dismissUpdate()
                    }
                    .transition(.move(edge: .top))
                }
                // P2-4: 偶然唤回 banner (未 dismiss 时)
                if let pick = serendipityPick, !serendipityDismissed {
                    SerendipityBanner(
                        pick: pick,
                        onOpen: { mem in
                            model.openMemory(mem)
                            serendipityDismissed = true
                        },
                        onDismiss: { serendipityDismissed = true }
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top))
                }
            }
        }
        .onAppear {
            columnVisibility = showInspector ? .all : .doubleColumn
            editorState.vaultRoot = model.vaultRoot
            gitWatcher.refresh(vaultRoot: model.vaultRoot)
            NotificationCenter.default.addObserver(
                forName: .showVaultSearch, object: nil, queue: .main
            ) { _ in openSearch() }
            // P2-2: 菜单栏 Graph 触发
            NotificationCenter.default.addObserver(
                forName: .showKnowledgeGraph, object: nil, queue: .main
            ) { _ in showGraph = true }
            // P2-3: 菜单栏 Insert Wikilink
            NotificationCenter.default.addObserver(
                forName: .showInsertWikilink, object: nil, queue: .main
            ) { _ in showInsertWikilink = true }
            // P7-T1: first-run welcome
            // P2-4: 偶然唤回 — vault 启动时挑 1 条 30+ 天没看的 durable
            if serendipityPick == nil {
                serendipityPick = SerendipitySelector.pick(from: model.ledger.memories)
            }
            if FirstRunTracker.shouldShow() {
                // 0.5s 延迟让主窗先起，避免 sheet 紧贴
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWelcome = true
                }
            }
        }
        .onChange(of: model.vaultRoot) { _ in
            // 用户手动换 vault 后重置 welcome（让他重选 LLM 适配新 vault）
            editorState.vaultRoot = model.vaultRoot
            FirstRunTracker.reset()
        }
        .onChange(of: showInspector) { newValue in
            columnVisibility = newValue ? .all : .doubleColumn
        }
        .sheet(isPresented: $showWelcome) {
            FirstRunWelcomeView { _ in
                showWelcome = false
                // welcome 关闭后立即 refresh 一次（用刚配的 vault）
                model.refreshStatus()
                gitWatcher.refresh(vaultRoot: model.vaultRoot)
            }
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

    private func openSearch(query: String? = nil) {
        if let query {
            vaultSearchText = query
        }
        showSearch = true
    }

    private func runDreamFromToolbar() {
        _ = editorState.flushIfDirty()
        Task { await model.runDream() }
    }

    private func toggleInspector() {
        showInspector.toggle()
        columnVisibility = showInspector ? .all : .doubleColumn
    }
}

private struct VaultTitleView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(subtitle)
        .frame(maxWidth: 280, alignment: .leading)
    }
}

private struct InspectorHiddenPlaceholder: View {
    let onShow: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Inspector Hidden")
                .font(.headline)
            Button {
                onShow()
            } label: {
                Label("Show Inspector", systemImage: "sidebar.right")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(.secondary)
    }
}

// MARK: - P6-T3: Update banner

struct UpdateBanner: View {
    let info: UpdateChecker.UpdateInfo
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("v\(info.latestVersion) 可用（当前 v\(info.currentVersion)）")
                    // 顺手修 (GUI audit 2026-06-14): dev build currentVersion
                    // 在 UpdateChecker.init 显式标 "dev", banner 出来
                    // "v0.11.2 可用（当前 vdev）" 明确标 dev build.
                    .font(.caption).fontWeight(.medium)
                Text("点击查看 release notes")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("View") {
                NSWorkspace.shared.open(info.releaseURL)
            }
            .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.accentColor.opacity(0.3)),
                 alignment: .bottom)
    }
}

// MARK: - VaultBrowser（左栏：文件树）

struct VaultBrowser: View {
    @EnvironmentObject var model: AppModel
    /// P2-A1: 4 个 wiki 子目录（entities/concepts/syntheses/archive）后端 Persister
    /// 都在写，v0.2.0 browser 只显示 concepts + archive，entities 和 syntheses 的内容
    /// 对用户隐形。现在补全 + 计数 badge + 可折叠。
    private struct WikiSection: Identifiable {
        let id: String
        let rel: String
        let system: String
        let color: Color
    }
    private let wikiSections: [WikiSection] = [
        .init(id: "entities",  rel: "wiki/entities",   system: "person.crop.circle",   color: .blue),
        .init(id: "concepts",  rel: "wiki/concepts",   system: "link",                 color: .accentColor),
        .init(id: "syntheses", rel: "wiki/syntheses",  system: "doc.text.magnifyingglass", color: .purple),
        .init(id: "archive",   rel: "wiki/archive",    system: "archivebox",           color: .gray),
    ]

    var body: some View {
        List(selection: $model.selectedFile) {
            Section("raw/  (\(model.status.rawCandidateCount) 候选)") {
                ForEach(rawFiles(), id: \.self) { url in
                    fileRow(url: url, system: "doc.text", tint: .secondary)
                }
                // P9 P0-4: 拖拽 / 导入入口
                // 既然 "扔文件进来" 是产品承诺，raw/ section 底部给一个明显的入口
                importHintRow
            }
            let notes = notesFiles()
            if !notes.isEmpty {
                Section("notes/  (\(notes.count) 可编辑)") {
                    ForEach(notes, id: \.self) { url in
                        fileRow(url: url, system: "square.and.pencil", tint: .green)
                    }
                }
            }
            ForEach(wikiSections) { section in
                let files = wikiFiles(under: section.rel)
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedSections.contains(section.id) || !files.isEmpty },
                        set: { newValue in
                            if newValue { expandedSections.insert(section.id) }
                            else { expandedSections.remove(section.id) }
                        }
                    )
                ) {
                    ForEach(files, id: \.self) { url in
                        fileRow(url: url, system: section.system, tint: section.color)
                    }
                } label: {
                    HStack {
                        Image(systemName: section.system).foregroundColor(section.color)
                        Text(section.rel + "/")
                        if !files.isEmpty {
                            Text("(\(files.count))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
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
        // P9 P0-4: 接受 Finder 拖拽进整面板
        // 拖到 raw/ 区域或者整个 List 都行，List.onDrop 拿拖入 URLs
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            // 拖入时的视觉反馈
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.05))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title)
                            Text("松手导入到 raw/")
                                .font(.caption).bold()
                        }
                        .foregroundColor(.accentColor)
                    }
                    .allowsHitTesting(false)
            }
        }
        // P9 P0-4: 监听菜单 Import to raw... 通知（Cmd-I）
        .onReceive(NotificationCenter.default.publisher(for: .dreamVaultImportToRaw)) { _ in
            openImportPanel()
        }
    }

    @State private var isDropTargeted: Bool = false
    @State private var importResultBanner: ImportResultBanner? = nil
    struct ImportResultBanner: Identifiable, Equatable {
        let id = UUID()
        let succeeded: Int
        let editable: Int
        let skipped: Int
        let failed: Int
    }

    @ViewBuilder
    private var importHintRow: some View {
        Button {
            openImportPanel()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.secondary)
                Text("拖 .md/.txt 进来，或点这里选文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("导入到 raw/；Markdown 会同时创建 notes/ 可编辑副本")
        // 浮动的导入结果反馈
        .overlay(alignment: .bottom) {
            if let banner = importResultBanner {
                Text("✓ 导入 \(banner.succeeded) 可编辑 \(banner.editable) 跳过 \(banner.skipped) 失败 \(banner.failed)")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .padding(.bottom, -28)
                    .transition(.opacity)
                    .id(banner.id)
                    .task(id: banner.id) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            withAnimation { importResultBanner = nil }
                        }
                    }
            }
        }
    }

    /// 处理拖入的 URLs（Finder 拖文件进来）
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var collected: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { collected.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            importURLs(collected)
        }
        return true
    }

    /// 走 import pipeline：调 RawImporter 然后刷新 + 显示结果
    private func importURLs(_ urls: [URL]) {
        let result = RawImporter.importToRaw(sourceURLs: urls, vaultRoot: model.vaultRoot)
        withAnimation { importResultBanner = ImportResultBanner(
            succeeded: result.succeeded.count,
            editable: result.editableCopies.count,
            skipped: result.skipped.count,
            failed: result.failed.count
        ) }
        if let firstEditable = result.editableCopies.first {
            model.selectedFile = firstEditable
        }
        model.refreshStatus()
        // stderr 留痕（log tab 能看到）
        if !result.succeeded.isEmpty {
            FileHandle.standardError.write(Data(
                "[VaultBrowser] imported \(result.succeeded.count) file(s) to raw/\n".utf8))
        }
        if !result.editableCopies.isEmpty {
            FileHandle.standardError.write(Data(
                "[VaultBrowser] created \(result.editableCopies.count) editable note copy/copies\n".utf8))
        }
        for s in result.skipped {
            FileHandle.standardError.write(Data(
                "[VaultBrowser] skipped: \(s)\n".utf8))
        }
        for f in result.failed {
            FileHandle.standardError.write(Data(
                "[VaultBrowser] failed: \(f)\n".utf8))
        }
    }

    /// 调 NSOpenPanel 选文件导入
    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        var contentTypes: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") { contentTypes.append(markdown) }
        if let text = UTType(filenameExtension: "txt") { contentTypes.append(text) }
        panel.allowedContentTypes = contentTypes
        panel.message = "选 .md / .txt 文件导入到 raw/"
        if panel.runModal() == .OK {
            importURLs(panel.urls)
        }
    }

    /// DisclosureGroup 折叠状态：默认全展开
    @State private var expandedSections: Set<String> = ["entities", "concepts", "syntheses", "archive"]

    @ViewBuilder
    private func fileRow(url: URL, system: String, tint: Color) -> some View {
        let relPath = FrontendPresentation.relativePath(of: url, vaultRoot: model.vaultRoot)
        let body = try? String(contentsOf: url, encoding: .utf8)
        let title = FrontendPresentation.sidebarTitle(relPath: relPath, body: body)
        let subtitle = FrontendPresentation.sidebarSubtitle(relPath: relPath)
        HStack(spacing: 8) {
            Image(systemName: system).foregroundColor(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
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
        }
        .tag(url as URL?)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Externally", systemImage: "arrow.up.right.square")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relPath, forType: .string)
            } label: {
                Label("Copy Relative Path", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                renameFile(url: url, relPath: relPath)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(!FrontendPresentation.canRenameSidebarItem(relPath: relPath))
        }
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
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return all
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func notesFiles() -> [URL] {
        markdownFiles(under: "notes")
    }

    /// 列出 wiki 子目录下 .md 文件（按文件名排序）
    private func wikiFiles(under rel: String) -> [URL] {
        markdownFiles(under: rel)
    }

    private func markdownFiles(under rel: String) -> [URL] {
        let dir = model.vaultRoot.appendingPathComponent(rel)
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return all
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func renameFile(url: URL, relPath: String) {
        guard FrontendPresentation.canRenameSidebarItem(relPath: relPath) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Note"
        alert.informativeText = "Enter a new Markdown filename."
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = url.lastPathComponent
        alert.accessoryView = textField
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        if (newName as NSString).pathExtension.isEmpty {
            newName += ".md"
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard destination != url else { return }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            if model.selectedFile == url {
                model.selectedFile = destination
            }
            model.refreshStatus()
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.messageText = "Rename Failed"
            errorAlert.runModal()
        }
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
    // P1 修复 (缺陷报告 §2.1): scroll target to jump from "Needs review" row to Conflicts GroupBox
    @State private var scrollToConflicts: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dreamHeader

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    statusBlock
                        .padding(12)
                }
                .frame(minHeight: 260)
                .onChange(of: scrollToConflicts) { shouldScroll in
                    if shouldScroll {
                        withAnimation { proxy.scrollTo("conflicts-anchor", anchor: .top) }
                        scrollToConflicts = false
                    }
                }
            }

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

    private var dreamHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Dream Inspector", systemImage: "moon.stars.fill")
                    .font(.headline)
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
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.isRunning)

                Button(role: .destructive) {
                    // P9: 不直接 rollback，先弹确认 dialog（让用户看到 commit msg + 文件数）
                    model.requestRollback()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(model.isRunning)
                .help("Rollback last dream commit")
                .confirmationDialog(
                    "确认回滚上次的 dream commit？",
                    isPresented: Binding(
                        get: { model.rollbackConfirmation != nil },
                        set: { if !$0 { model.cancelRollback() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("确认回滚", role: .destructive) {
                        model.confirmRollback()
                    }
                    Button("取消", role: .cancel) {
                        model.cancelRollback()
                    }
                } message: {
                    if let c = model.rollbackConfirmation {
                        Text("""
                        Commit: \(c.shortHash)
                        Message: \(c.subject)
                        Author: \(c.author)
                        Files: \(c.changedFiles)
                        Date: \(c.date.formatted(date: .abbreviated, time: .shortened))

                        回滚会生成一个反向 commit 撤销这些改动。
                        """)
                    }
                }

                Spacer()

                Button {
                    model.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh status")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 5) {
                    row("Raw candidates", value: "\(model.status.rawCandidateCount)")
                    row("Total memories", value: "\(model.status.totalMemories)")
                    row("Durable", value: "\(model.status.durableCount)")
                    row("Candidate", value: "\(model.status.candidateCount)")
                    row("Archived", value: "\(model.status.archivedCount)")
                    // P1 严重修复 (缺陷报告 §2.1): "Needs review" 行可点击跳转矛盾 GroupBox
                    // 之前只是只读 count, 用户看不到"待裁决"区. 现在点击跳到下面 Conflicts
                    // GroupBox 第一个有矛盾的记忆 (ConflictResolutionView 行内裁决).
                    if model.status.withContradictsCount > 0 {
                        Button {
                            withAnimation { scrollToConflicts = true }
                        } label: {
                            HStack {
                                Text("Needs review")
                                Spacer()
                                Text("\(model.status.withContradictsCount) →")
                                    .foregroundColor(.orange)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        row("Needs review", value: "\(model.status.withContradictsCount)")
                    }
                }
                .padding(.top, 2)
            }

            // P8: 预算状态（Dream tab 顶部 + Budget tab 详细表）
            // 这里只显示紧凑版，详细见 Settings → Budget
            if let bs = model.budgetSnapshot {
                GroupBox("Budget") {
                    VStack(alignment: .leading, spacing: 5) {
                        row("Today", value: FrontendPresentation.budgetUsage(count: bs.todayCount, limit: bs.maxCallsPerDay))
                        row("Month", value: FrontendPresentation.monthlySpend(cost: bs.monthCost, limit: bs.monthlyBudgetUSD))
                        if bs.isOverBudget {
                            Label("Over budget", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if bs.monthlyBudgetUSD > 0 && bs.monthCost > bs.monthlyBudgetUSD * 0.8 {
                            Label("Approaching budget limit", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            // P3-T1: 行内矛盾裁决（计数 > 0 才显示）
            if model.status.withContradictsCount > 0 {
                GroupBox("Conflicts") {
                    ConflictResolutionView(ledger: model.ledger)
                        .padding(.top, 2)
                }
                .id("conflicts-anchor")  // P1 修复 §2.1: ScrollViewReader 跳转锚点
            }

            // P3-C3: 5 步骤 stage 进度
            if model.isRunning || model.lastOutcome != nil || model.lastError != nil {
                GroupBox("Pipeline") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.dreamStages) { stage in
                            stageRow(stage)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if let r = model.lastOutcome {
                GroupBox("Last Run") {
                    VStack(alignment: .leading, spacing: 5) {
                        row("Gathered", value: "\(r.gatheredCount)")
                        row("Accepted", value: "\(r.acceptedCount)")
                        row("Archived", value: "\(r.archivedCount)")
                        row("Needs review", value: "\(r.needsReviewCount)")
                        row("Committed", value: r.committed ? "✓" : "—")
                    }
                    .padding(.top, 2)
                }
            }
            if let err = model.lastError {
                GroupBox("Error") {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: DreamStage) -> some View {
        HStack(spacing: 6) {
            // 图标按状态切换
            switch stage.state {
            case .pending:
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .frame(width: 16)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .frame(width: 16)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
            }
            Image(systemName: stage.system)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(stage.title)
                .font(.caption)
            Spacer()
            // detail 文字
            switch stage.state {
            case .success(let detail), .failed(let detail):
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            default:
                EmptyView()
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
