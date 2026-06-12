import Foundation
import SwiftUI
import AppKit
import DreamEngine

// MARK: - dream 二进制顶层入口
//
// 路由（默认 GUI，CLI 显式 opt-in）：
//   argv[1] 是已知 CLI 子命令（run/rollback/status/help/version/init）→ 走 CLI
//   argv[1] == "app"                                              → 走 GUI（显式）
//   其他（空 / Finder 双击 / open / Spotlight / 自定义参数）      → 默认走 GUI
//
// 关键：双击 .app 时 argv 可能是 [Contents/MacOS/dream]，没有 "app" 也没有子命令。
// 这种情况下回到默认 GUI 路径，否则会闪退到 CLI 帮助。
//
// 用 @main 在这里 —— SwiftUI 那边不再写 @main。

@main
struct DreamEntry {
    /// 已知 CLI 子命令集合；只有命中这些才走 CLI，其他全部默认走 GUI。
    /// 完整列表见 CLI.swift `DreamCLI.main()` 的 switch 块。
    private static let cliSubcommands: Set<String> = [
        "run", "rollback", "status", "report", "help", "version",
    ]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let firstArg = args.first

        // 显式 "app" 走 GUI；未知/空走 GUI（兼容双击 / Finder / Spotlight / open 启动）
        if firstArg == "app" || firstArg == nil || !cliSubcommands.contains(firstArg ?? "") {
            launchGUI(args: args)
        } else {
            launchCLI()
        }
    }

    /// 启动 SwiftUI GUI：必须比 NSApplication init 早设 UserDefaults，
    /// 否则 CFPrefsD 会在 applicationWillFinishLaunching 之前加载默认 true，
    /// 卡在 "Restoring windows" 然后 0 窗出来。
    private static func launchGUI(args: [String]) {
        // 把 --vault / -v 解析出来，写进 UserDefaults 让 AppModel 读
        // （AppModel 是 @MainActor，@StateObject 不接受构造参数——用 UserDefaults 中转）
        if let vault = parseVaultArg(args) {
            UserDefaults.standard.set(vault, forKey: "DreamVaultInitialVault")
        }
        UserDefaults.standard.set(false, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.synchronize()
        DreamVaultApp.main()
    }

    /// CLI 路径：DreamCLI.main() 是 async，起 Task 跑，进程挂起等结果
    private static func launchCLI() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let code = await DreamCLI.main()
            Foundation.exit(code)
        }
        // 死等 —— DreamCLI.main() 内部调 Foundation.exit() 终止进程
        sema.wait()
    }

    /// 从 argv 解析 --vault <path> 或 --vault=<path>。命中返回绝对 URL，否则 nil。
    private static func parseVaultArg(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--vault" || a == "-v" {
                if i + 1 < args.count { return args[i + 1] }
                return nil
            }
            if a.hasPrefix("--vault=") {
                return String(a.dropFirst("--vault=".count))
            }
            i += 1
        }
        return nil
    }

    /// P0-3: GUI 启动期解析 vault 路径。和 AppModel.init 同一套优先顺序：
    /// 1. UserDefaults["DreamVaultInitialVault"]（launchGUI 从 --vault 写入）
    /// 2. DREAMVAULT_VAULT 环境变量
    /// 3. ~/.dreamvault
    /// 用在 AppDelegate 的 raw chmod 保护，确保自定义 vault 也能被挂只读。
    static func resolveInitialVault() -> URL {
        if let fromUserDefaults = UserDefaults.standard.string(forKey: "DreamVaultInitialVault") {
            return URL(fileURLWithPath: fromUserDefaults, isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.dreamvault", isDirectory: true)
    }
}

// MARK: - SwiftUI App

/// AppDelegate：显式把 activation policy 设为 .regular（窗口可见在 dock/Finder）
/// + 在 didFinishLaunching 时 activate NSApp
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 比 applicationDidFinishLaunching 更早设置 activation policy
        NSApp.setActivationPolicy(.regular)
        // 禁掉窗口状态恢复 —— SwiftUI 的 WindowGroup 没法 satisfy restore
        // (system default + bundle 没保存 state)，否则启动会卡在
        // "Restoring windows" 出现 0 窗。这是已知 macOS 13 SwiftUI 行为。
        UserDefaults.standard.set(false, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.synchronize()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("[DreamVault] applicationDidFinishLaunching fired\n".utf8))
        // 架构第 1 节末段："app 启动时 chmod" —— GUI 启动就把 raw/ 挂为只读。
        // DreamCycle.runOnce 也会再调一次，但 GUI 启动到第一次 Run Dream 之间这段时间
        // 也得守住（用户可能手动编辑 raw/、外部编辑器可能打开 raw/）。
        // P0-3: 必须用与 AppModel 一致的 vault 解析顺序（--vault UserDefaults > env > default），
        // 否则 --vault 自定义 vault 在启动后没有 raw chmod 保护
        let vaultRoot = DreamEntry.resolveInitialVault()
        try? RawReadonlyGuard.makeReadonly(vaultRoot: vaultRoot)
        FileHandle.standardError.write(Data("[DreamVault] RawReadonlyGuard applied at \(vaultRoot.path)/raw\n".utf8))
        // **P0-3 fix**: AppModel 已经初始化完，可以用同一个 vault 了
        // —— 在这里清 UserDefaults（之前 AppModel.init 清，AppDelegate 拿不到）
        UserDefaults.standard.removeObject(forKey: "DreamVaultInitialVault")
        // SwiftUI 的 WindowGroup 在 macOS 13 SwiftPM 编译产物下经常因为
        // state restoration race 不创建窗口，这里兜底：如果 1.5s 后还没窗口，
        // 直接 NSWindow 创一个 native 的 MainView 容器。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            let winCount = NSApp.windows.count
            FileHandle.standardError.write(Data("[DreamVault] post-1.5s window count = \(winCount)\n".utf8))
            if winCount == 0 {
                self.installFallbackWindow()
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭最后一窗就退出（GUI 是按需启动的，不是后台守护进程）
        return true
    }

    private func installFallbackWindow() {
        // AppModel 是 @MainActor，从 main thread 调即可
        DispatchQueue.main.async {
            // 居中到主屏可见区（避开 dock / menu bar）
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1440, height: 900)
            let winSize = NSSize(width: 1100, height: 700)
            let origin = NSPoint(
                x: screenFrame.origin.x + (screenFrame.width - winSize.width) / 2,
                y: screenFrame.origin.y + (screenFrame.height - winSize.height) / 2
            )
            let win = NSWindow(
                contentRect: NSRect(origin: origin, size: winSize),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            win.title = "DreamVault"
            win.isReleasedWhenClosed = false

            // 在 NSHostingView 里塞 SwiftUI 的 MainView（共享 AppModel）
            let model = AppModel()
            let host = NSHostingView(rootView: MainView().environmentObject(model))
            host.autoresizingMask = [.width, .height]
            win.contentView = host
            win.setContentSize(winSize)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            FileHandle.standardError.write(Data("[DreamVault] Fallback NSWindow installed at (\(Int(origin.x)),\(Int(origin.y)))\n".utf8))
        }
    }
}

struct DreamVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()
    /// P3-C1: 原生菜单 + 标准 macOS key bindings。
    /// macOS 13 用 @FocusedValue（macOS 14+ 才升 @FocusedObject）。
    /// MainView 在 view 树里设置这两个 focused value，.commands 自动读到。
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.editorState) private var editorState

    private var menuModel: AppModel { focusedModel ?? model }

    var body: some Scene {
        WindowGroup("DreamVault") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 去掉默认 New File（用我们的 New Note 替代）
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    AppActions.newNote(model: menuModel, editorState: editorState)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // File 菜单（在 New Item 之后插入 Open / Reveal）
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open Vault...") { AppActions.openVault(model: menuModel) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open File...") { AppActions.openFile(model: menuModel) }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Reveal in Finder") {
                    if let f = menuModel.selectedFile {
                        NSWorkspace.shared.activateFileViewerSelecting([f])
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(menuModel.selectedFile == nil)
                Divider()
                Button("Export Diagnostics...") {
                    AppActions.exportDiagnostics(model: menuModel)
                }
            }
            // View 菜单
            CommandMenu("View") {
                Button("Source") {
                    editorState?.mode = .source
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Preview") {
                    editorState?.mode = .preview
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("Split") {
                    editorState?.mode = .split
                }
                .keyboardShortcut("3", modifiers: .command)
            }
            // Dream 菜单
            CommandMenu("Dream") {
                Button("Run Dream") {
                    _ = editorState?.flushIfDirty()
                    Task { await menuModel.runDream() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(menuModel.isRunning)
                Button("Refresh Status") { menuModel.refreshStatus() }
                Divider()
                Button(role: .destructive) {
                    menuModel.rollback()
                } label: {
                    Text("Rollback Last Dream")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(menuModel.isRunning)
            }
            // Help 菜单加项目链接
            CommandGroup(replacing: .help) {
                Link("DreamVault on GitHub",
                     destination: URL(string: "https://github.com/OmixNet/DreamVault")!)
                Link("Architecture & Docs",
                     destination: URL(string: "https://github.com/OmixNet/DreamVault/blob/main/docs/ARCHITECTURE.md")!)
            }
        }
    }
}

// MARK: - 菜单 action helpers（避免在 View body 里堆一堆闭包）

@MainActor
enum AppActions {
    /// 在 vault 根创建一个新的 .md 文件并打开
    static func newNote(model: AppModel, editorState: EditorState?) {
        // P0-1: 先 flush 当前 editor
        _ = editorState?.flushIfDirty()
        let stamp = Self.timestamp()
        let newURL = model.vaultRoot.appendingPathComponent("\(stamp).md")
        let initial = "# \(stamp)\n\n"
        do {
            try initial.write(to: newURL, atomically: true, encoding: .utf8)
            model.selectedFile = newURL
        } catch {
            FileHandle.standardError.write(Data(
                "[AppActions] newNote 写盘失败：\(error.localizedDescription)\n".utf8))
        }
    }

    /// NSOpenPanel 选 vault 目录
    static func openVault(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        panel.message = "选择 vault 根目录（含 raw/ + wiki/ + .git/）"
        if panel.runModal() == .OK, let url = panel.url {
            model.switchVault(to: url)
        }
    }

    /// NSOpenPanel 选 vault 内的 .md 文件
    static func openFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.directoryURL = model.vaultRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.selectedFile = url
        }
    }

    /// 收集诊断信息（vaultRoot / status / logLines / git HEAD）写到桌面
    static func exportDiagnostics(model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dreamvault-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines: [String] = []
        lines.append("=== DreamVault Diagnostics ===")
        lines.append("Date: \(Date())")
        lines.append("Vault: \(model.vaultRoot.path)")
        lines.append("Selected file: \(model.selectedFile?.path ?? "nil")")
        lines.append("")
        lines.append("--- Status ---")
        lines.append("raw candidate: \(model.status.rawCandidateCount)")
        lines.append("total memories: \(model.status.totalMemories)")
        lines.append("durable: \(model.status.durableCount)")
        lines.append("candidate: \(model.status.candidateCount)")
        lines.append("archived: \(model.status.archivedCount)")
        lines.append("needs review: \(model.status.withContradictsCount)")
        if let r = model.lastOutcome {
            lines.append("")
            lines.append("--- Last Run ---")
            lines.append("gathered: \(r.gatheredCount)")
            lines.append("accepted: \(r.acceptedCount)")
            lines.append("archived: \(r.archivedCount)")
            lines.append("needs review: \(r.needsReviewCount)")
            lines.append("committed: \(r.committed)")
        }
        if let err = model.lastError {
            lines.append("")
            lines.append("--- Last Error ---")
            lines.append(err)
        }
        lines.append("")
        lines.append("--- Log (last 100 lines) ---")
        lines.append(contentsOf: model.logLines.suffix(100))
        // git HEAD
        let git = GitRunner(repoRoot: model.vaultRoot)
        if let head = try? git.run(["log", "--oneline", "-5"] as [String]) {
            lines.append("")
            lines.append("--- git HEAD ---")
            lines.append(head)
        }
        let content = lines.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data(
                "[AppActions] exportDiagnostics 失败：\(error.localizedDescription)\n".utf8))
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - FocusedObject key 桥接 AppModel + EditorState 到 .commands

private struct AppModelFocusedKey: FocusedValueKey { typealias Value = AppModel }
private struct EditorStateFocusedKey: FocusedValueKey { typealias Value = EditorState }

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
    var editorState: EditorState? {
        get { self[EditorStateFocusedKey.self] }
        set { self[EditorStateFocusedKey.self] = newValue }
    }
}

// MARK: - AppModel（@MainActor ObservableObject）
//
// 三个面板共享状态：
// - vaultRoot: 当前 vault 路径（来自 --vault 或 DREAMVAULT_VAULT）
// - selectedFile: 当前选中的 vault 内文件（绝对路径）
// - lastReport: 最近一次 dream-run 的 DreamCycle.Outcome（nil 表示还没跑过）
// - status: 实时 vault 状态（raw 候选数 / ledger 三态 / 矛盾数 / 最近 report 路径）

@MainActor
final class AppModel: ObservableObject {
    @Published var vaultRoot: URL
    @Published var selectedFile: URL? = nil
    @Published var lastOutcome: DreamCycle.Outcome? = nil
    @Published var lastError: String? = nil
    @Published var isRunning: Bool = false
    @Published var status: VaultStatus = .init()
    @Published var reportPath: String? = nil
    @Published var logLines: [String] = []
    // T1 起 EditorState 接管 buffer / dirty 状态；保留 @Published 占位以兼容
    // 其他可能直接读这两个字段的视图代码（实际 EditorPane 自己用 EditorState）
    @Published var textEditorContent: String = ""
    @Published var textEditorDirty: Bool = false

    /// GUI 模式默认 vault 路径解析顺序（最高优先在前）：
    /// 1. init(vault:) 显式传入
    /// 2. UserDefaults["DreamVaultInitialVault"]（Entry.swift 从 --vault 写入）
    /// 3. DREAMVAULT_VAULT 环境变量
    /// 4. ~/.dreamvault
    init(vault: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"]
        let fromUserDefaults = UserDefaults.standard.string(forKey: "DreamVaultInitialVault")
        let defaultPath = vault
            ?? fromUserDefaults.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (env.map { URL(fileURLWithPath: $0, isDirectory: true) })
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.dreamvault", isDirectory: true)
        self.vaultRoot = defaultPath
        // **P0-3 fix**: 不在这里清 UserDefaults —— AppDelegate 的
        // applicationDidFinishLaunching 也要读这个 key 拿 vault 来 chmod raw/。
        // SwiftUI @StateObject 初始化时机早于 applicationDidFinishLaunching，
        // 之前在这里清会让 AppDelegate 拿不到 custom vault。
        // 清的动作下移到 AppDelegate（见 installFallbackWindow 之后）。
        refreshStatus()
    }

    /// 运行时切换 vault（GUI 内例如 File→Open Vault... 菜单调用）。
    /// 切换前会尝试把当前编辑器脏内容 flush（提示上层先保存）。
    func switchVault(to url: URL) {
        self.vaultRoot = url
        self.selectedFile = nil
        self.textEditorContent = ""
        self.textEditorDirty = false
        self.lastOutcome = nil
        self.lastError = nil
        refreshStatus()
    }

    func refreshStatus() {
        status = VaultStatus.load(from: vaultRoot)
    }

    /// GUI 内的 Run Dream。直接调 DreamCycle，不开子进程
    func runDream() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        logLines.append("--- dream 开始 \(Self.stamp(Date())) ---")
        defer { isRunning = false }
        do {
            let llm = GlobalOptions().llmProvider()  // 走环境变量
            let git = GitRunner(repoRoot: vaultRoot)
            let cycle = DreamCycle(vaultRoot: vaultRoot, llm: llm, git: git)
            let outcome = try await cycle.runOnce()
            lastOutcome = outcome
            reportPath = outcome.reportPath
            logLines.append("gathered=\(outcome.gatheredCount) accepted=\(outcome.acceptedCount) committed=\(outcome.committed)")
            refreshStatus()
        } catch let e as DreamCycle.DreamError {
            lastError = String(describing: e)
            logLines.append("FAIL: \(e)")
        } catch {
            lastError = error.localizedDescription
            logLines.append("FAIL: \(error.localizedDescription)")
        }
    }

    func rollback() {
        let git = GitRunner(repoRoot: vaultRoot)
        do {
            let head = try git.headHash()
            try git.revertLast()
            logLines.append("revert \(head.prefix(7)) OK")
            refreshStatus()
        } catch {
            lastError = "rollback 失败: \(error)"
            logLines.append("rollback 失败: \(error)")
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - VaultStatus（status 命令对应物，给 GUI 面板用）

struct VaultStatus {
    var rawCandidateCount: Int = 0
    var totalMemories: Int = 0
    var durableCount: Int = 0
    var candidateCount: Int = 0
    var archivedCount: Int = 0
    var withContradictsCount: Int = 0
    var lastReportPath: String? = nil

    static func load(from vaultRoot: URL) -> VaultStatus {
        var s = VaultStatus()
        let fm = FileManager.default

        // raw 候选
        let rawDir = vaultRoot.appendingPathComponent("raw")
        if fm.fileExists(atPath: rawDir.path) {
            let processed = Gatherer.loadProcessedRegistry(vaultRoot: vaultRoot)
            let files = (try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)) ?? []
            s.rawCandidateCount = files.filter { f in
                let rel = "raw/\(f.lastPathComponent)"
                if processed.contains(rel) { return false }
                guard let content = try? String(contentsOf: f, encoding: .utf8) else { return false }
                return content.contains("processed: false")
            }.count
        }

        // ledger 三态
        let ledger = Persister.loadLedger(vaultRoot: vaultRoot)
        s.totalMemories = ledger.memories.count
        s.durableCount = ledger.memories.filter { $0.status == .durable }.count
        s.candidateCount = ledger.memories.filter { $0.status == .candidate }.count
        s.archivedCount = ledger.memories.filter { $0.status == .archived }.count
        s.withContradictsCount = ledger.memories.filter { !$0.contradicts.isEmpty }.count

        // 最近 report
        let reportsDir = vaultRoot.appendingPathComponent(".dream/reports")
        let key: URLResourceKey = .creationDateKey
        let reports = (try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [key])) ?? []
        s.lastReportPath = reports
            .sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [key]).creationDate) ?? .distantPast
                let rd = (try? rhs.resourceValues(forKeys: [key]).creationDate) ?? .distantPast
                return ld > rd
            }
            .first?
            .path
        return s
    }
}
