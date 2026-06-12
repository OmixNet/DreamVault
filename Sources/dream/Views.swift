import SwiftUI
import AppKit
import DreamEngine

// MARK: - MainView（3 栏 NavigationSplitView）

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var editorState = EditorState()
    @StateObject private var gitWatcher = GitStatusWatcher()
    @StateObject private var searcher = VaultSearcher()
    @StateObject private var updateChecker = UpdateChecker()
    /// P7-T1: 首次启动弹 welcome sheet
    @State private var showWelcome: Bool = false

    /// P3-C1: 把 model 和 editorState 写进 FocusedValues，菜单 command 才能读
    var body: some View {
        content
            .focusedSceneValue(\.appModel, model)
            .focusedSceneValue(\.editorState, editorState)
    }

    @State private var showSearch = false

    @ViewBuilder
    private var content: some View {
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSearch.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search vault (Cmd-Shift-F)")
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(searcher: searcher, model: model) {
                showSearch = false
            }
        }
        // P6-T3: 启动后 3s 静默检查更新（不打扰）
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            updateChecker.check()
        }
        .safeAreaInset(edge: .top) {
            if let info = updateChecker.update, info.isUpdateAvailable {
                UpdateBanner(info: info) {
                    updateChecker.dismissUpdate()
                }
                .transition(.move(edge: .top))
            }
        }
        .onAppear {
            gitWatcher.refresh(vaultRoot: model.vaultRoot)
            NotificationCenter.default.addObserver(
                forName: .showVaultSearch, object: nil, queue: .main
            ) { _ in showSearch = true }
            // P7-T1: first-run welcome
            if FirstRunTracker.shouldShow() {
                // 0.5s 延迟让主窗先起，避免 sheet 紧贴
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showWelcome = true
                }
            }
        }
        .onChange(of: model.vaultRoot) { _ in
            // 用户手动换 vault 后重置 welcome（让他重选 LLM 适配新 vault）
            FirstRunTracker.reset()
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
    }

    /// DisclosureGroup 折叠状态：默认全展开
    @State private var expandedSections: Set<String> = ["entities", "concepts", "syntheses", "archive"]

    @ViewBuilder
    private func fileRow(url: URL, system: String, tint: Color) -> some View {
        HStack {
            Image(systemName: system).foregroundColor(tint)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .tag(url as URL?)
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
    /// 列出 wiki 子目录下 .md 文件（按文件名排序）
    private func wikiFiles(under rel: String) -> [URL] {
        let dir = model.vaultRoot.appendingPathComponent(rel)
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
                        // P9: 不直接 rollback，先弹确认 dialog（让用户看到 commit msg + 文件数）
                        model.requestRollback()
                    } label: {
                        Label("Rollback", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isRunning)
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

            // P8: 预算状态（Dream tab 顶部 + Budget tab 详细表）
            // 这里只显示紧凑版，详细见 Settings → Budget
            if let bs = model.budgetSnapshot {
                Divider().padding(.vertical, 4)
                Text("Budget").font(.subheadline).bold()
                row("today", value: "\(bs.todayCount)/\(bs.maxCallsPerDay == 0 ? "∞" : "\(bs.maxCallsPerDay)") calls")
                row("month", value: String(format: "$%.2f", bs.monthCost) + "/\(bs.monthlyBudgetUSD == 0 ? "∞" : String(format: "$%.2f", bs.monthlyBudgetUSD))")
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

            // P3-T1: 行内矛盾裁决（计数 > 0 才显示）
            if model.status.withContradictsCount > 0 {
                Divider().padding(.vertical, 4)
                Text("Conflicts (\(model.status.withContradictsCount))")
                    .font(.subheadline).bold()
                ConflictResolutionView(ledger: model.ledger)
            }

            // P3-C3: 5 步骤 stage 进度
            if model.isRunning || model.lastOutcome != nil || model.lastError != nil {
                Divider().padding(.vertical, 4)
                Text("Pipeline").font(.subheadline).bold()
                ForEach(model.dreamStages) { stage in
                    stageRow(stage)
                }
            }

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
