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
    /// 已知 CLI 子命令集合；只有命中这些才走 CLI。其他全部默认走 GUI。
    /// 完整列表见 CLI.swift `DreamCLI.dispatch()` 的 switch 块。
    private static let cliSubcommands: Set<String> = [
        "run", "rollback", "status", "report", "help", "version",
    ]
    /// 启动模式判别：哪些首参明确走 GUI（其他默认进 CLI 走 default 报错路径）
    private static let guiExplicitTokens: Set<String> = [
        "app",          // 显式启动 GUI
    ]
    /// 从 Finder / Spotlight / open / 双击 .app 启动时 argv 通常是 [Contents/MacOS/dream]，
    /// firstArg 为 nil。判断"非用户主动传参"的标准：firstArg == nil 或 firstArg 以 "-" 开头（flag）。
    /// SwiftUI App.main() 自身会把 bundle argv 转成 SDK argv 列表，所以这部分我们不接管。
    private static func looksLikeNoArgument(_ firstArg: String?) -> Bool {
        // nil = 没人传参（双击 / Finder / open）；或者 firstArg 以 - 开头（看起来像 GUI 自己带的 flag）
        return firstArg == nil
    }
    private static let legacyInitialVaultKey = "DreamVaultInitialVault"
    private static var processLaunchVaultPath: String?

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let firstArg = args.first

        // 路由规则：
        //   firstArg == nil            → GUI（Finder/Spotlight/双击）
        //   firstArg == "app"          → GUI（显式）
        //   firstArg 是已知 CLI 子命令 → CLI
        //   其他所有（"nonsense"、"init"、自定义参数） → CLI，让 CLI.default 分支报错
        //
        // P8 修复：之前这个分支把任何未命中 cliSubcommands 的参数（包括 init / nonsense）都丢进 GUI，
        // 导致 CLI 用户敲错命令时反而启了一个 SwiftUI 窗口。现在统一进 CLI 走 default 报错。
        if looksLikeNoArgument(firstArg) || firstArg == "app" {
            launchGUI(args: args)
        } else {
            launchCLI()
        }
    }

    /// 静态分析辅助：判断一个首参是否明确走 CLI
    /// 暴露出来给 test 用，避免测试重复这套 if 逻辑
    static func isCLIRoute(_ firstArg: String?) -> Bool {
        if looksLikeNoArgument(firstArg) { return false }
        if firstArg == "app" { return false }
        return true
    }

    /// 启动 SwiftUI GUI：必须比 NSApplication init 早设 UserDefaults，
    /// 否则 CFPrefsD 会在 applicationWillFinishLaunching 之前加载默认 true，
    /// 卡在 "Restoring windows" 然后 0 窗出来。
    private static func launchGUI(args: [String]) {
        // 把 --vault / -v 解析出来放进进程内缓存；UserDefaults 只保留为旧版本桥接。
        // SwiftUI @StateObject 和 NSApplicationDelegate 的初始化顺序在不同启动方式下不稳定，
        // 所以不能靠一个会被清掉的临时 UserDefaults key 作为唯一来源。
        if let vault = parseVaultArg(args) {
            processLaunchVaultPath = vault
            UserDefaults.standard.set(vault, forKey: legacyInitialVaultKey)
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

    /// P0-3: GUI 启动期解析 vault 路径。AppDelegate 和 AppModel 必须走同一套入口：
    /// 1. 进程内启动参数缓存（launchGUI 从 --vault 写入）
    /// 2. UserDefaults["DreamVaultInitialVault"]（旧版本桥接；读到后也缓存到进程内）
    /// 3. DREAMVAULT_VAULT 环境变量
    /// 4. Settings 里保存的 vaultPath
    /// 5. ~/.dreamvault
    /// 用在 AppDelegate 的 raw chmod 保护，确保自定义 vault 也能被挂只读。
    static func resolveInitialVault() -> URL {
        if let processLaunchVaultPath = nonEmptyPath(processLaunchVaultPath) {
            return vaultURL(from: processLaunchVaultPath)
        }
        if let fromUserDefaults = nonEmptyPath(UserDefaults.standard.string(forKey: legacyInitialVaultKey)) {
            processLaunchVaultPath = fromUserDefaults
            return vaultURL(from: fromUserDefaults)
        }
        if let env = nonEmptyPath(ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"]) {
            return vaultURL(from: env)
        }
        let settings = DreamSettings.load()
        if let settingsVault = nonEmptyPath(settings.vaultPath) {
            return vaultURL(from: settingsVault)
        }
        return vaultURL(from: NSHomeDirectory() + "/.dreamvault")
    }

    private static func nonEmptyPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func vaultURL(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    #if DEBUG
    static func resetLaunchVaultForTesting() {
        processLaunchVaultPath = nil
    }
    #endif
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
        // 清掉旧版 UserDefaults 桥接，避免本次 --vault 污染下一次双击启动。
        // 真正的本进程来源已经在 DreamEntry.resolveInitialVault() 缓存下来。
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
    /// P5-T2: 全局 color scheme 覆盖（system/light/dark）
    @StateObject private var colorScheme = ColorSchemeController.shared
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
                .preferredColorScheme(colorScheme.preferredColorScheme)
                .onAppear {
                    // P2-1: 启动时把 AppModel 注入菜单栏 (idempotent, 多次调安全)
                    MenuBarController.shared.start(model: model)
                }
        }
        .windowResizability(.contentMinSize)
        // P3-T7: Settings scene（独立于 WindowGroup，SwiftUI 自动挂"Preferences…Cmd-,"菜单项）
        Settings {
            SettingsView(vaultPath: model.vaultRoot.path)
        }
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
                Button("Search Vault...") {
                    // P3-T8: 通过 NotificationCenter 让 MainView 打开 search sheet
                    NotificationCenter.default.post(name: .showVaultSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Backup Vault…") { AppActions.backupVault(model: menuModel) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Restore Vault…") { AppActions.restoreVault(model: menuModel) }
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
                // P9 P0-4: Import 入口（菜单 + 快捷键 Cmd-I）
                Button {
                    NotificationCenter.default.post(name: .dreamVaultImportToRaw, object: nil)
                } label: {
                    Label("Import to raw…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: .command)
                Button(role: .destructive) {
                    // P9: 不直接 rollback，走 confirmationDialog
                    menuModel.requestRollback()
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

// P3-T8: Search sheet 触发通知
extension Notification.Name {
    public static let showVaultSearch = Notification.Name("com.OmixNet.dreamvault.showSearch")
    /// P2-2: 弹 Knowledge Graph 窗口
    public static let showKnowledgeGraph = Notification.Name("com.OmixNet.dreamvault.showGraph")
    /// P2-3: 弹 Insert Wikilink 输入框
    public static let showInsertWikilink = Notification.Name("com.OmixNet.dreamvault.insertWikilink")
    // P9 P0-4: 菜单 Import → 触发 VaultBrowser 弹 NSOpenPanel
    public static let dreamVaultImportToRaw = Notification.Name("com.OmixNet.dreamvault.importToRaw")
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
    /// P2-1: 菜单栏 Search… — 复用 SearchSheet (通过 Notification 触发)
    static func openSearch(model: AppModel) {
        NotificationCenter.default.post(name: .showVaultSearch, object: nil)
    }

    /// P2-2: 菜单栏 Knowledge Graph — 弹 GraphWindow
    static func openGraph(model: AppModel) {
        NotificationCenter.default.post(name: .showKnowledgeGraph, object: nil)
    }

    /// P2-3: 菜单栏 Insert Wikilink — 弹输入框, 插入 [[target]] 到光标
    static func insertWikilink(model: AppModel) {
        NotificationCenter.default.post(name: .showInsertWikilink, object: nil)
    }

    /// P2-1: 菜单栏 Recent Memory — 跳到该记忆的源文件并打开编辑器
    static func openMemory(_ mem: Memory, model: AppModel) {
        guard let first = mem.sources.first else { return }
        let url = model.vaultRoot.appendingPathComponent(first.file)
        model.selectedFile = url
    }

    static func openVault(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        panel.message = "选择 vault 根目录（含 raw/ + wiki/ + .git/）"
        if panel.runModal() == .OK, let url = panel.url {
            model.switchVault(to: url)
            try? RawReadonlyGuard.makeReadonly(vaultRoot: url)
            var settings = DreamSettings.load()
            settings.vaultPath = url.path
            settings.save()
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
            guard EditorState.isDescendant(url, of: model.vaultRoot) else {
                let alert = NSAlert()
                alert.messageText = "File Outside Vault"
                alert.informativeText = "Choose a Markdown file inside the current DreamVault folder."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
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

    // P7-T2: Vault backup / restore helpers
    static func backupVault(model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Backup vault to zip"
        alert.informativeText = "把 \(model.vaultRoot.lastPathComponent) 整个（含 .git + .dream + raw + wiki）打包到 ~/Desktop/"
        alert.addButton(withTitle: "Backup")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let backup = VaultBackup()
                let url = try backup.backup(vaultRoot: model.vaultRoot)
                let done = NSAlert()
                done.messageText = "Backup 完成"
                done.informativeText = url.path
                done.addButton(withTitle: "Reveal in Finder")
                done.addButton(withTitle: "OK")
                if done.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                let e = NSAlert(error: error)
                e.messageText = "Backup 失败"
                e.runModal()
            }
        }
    }

    static func restoreVault(model: AppModel) {
        // 选 zip
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "zip")].compactMap { $0 }
        panel.prompt = "Choose backup zip"
        if panel.runModal() != .OK || panel.url == nil { return }
        let zipURL = panel.url!

        // 选目标 vault
        let dirPanel = NSOpenPanel()
        dirPanel.canChooseFiles = false
        dirPanel.canChooseDirectories = true
        dirPanel.allowsMultipleSelection = false
        dirPanel.prompt = "Choose target vault directory"
        dirPanel.message = "目标 vault 必须是空目录（不含 .DS_Store）"
        if dirPanel.runModal() != .OK || dirPanel.url == nil { return }
        let dest = dirPanel.url!

        // 二次确认
        let confirm = NSAlert()
        confirm.messageText = "Restore from backup?"
        confirm.informativeText = """
        From: \(zipURL.path)
        To:   \(dest.path)

        目标 vault 必须空。如果有内容会被拒绝（不会覆盖）。
        """
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")
        if confirm.runModal() != .alertFirstButtonReturn { return }

        do {
            let backup = VaultBackup()
            try backup.restore(zipFile: zipURL, to: dest)
            // 切 AppModel 到新 vault
            model.switchVault(to: dest)
            let done = NSAlert()
            done.messageText = "Restore 完成"
            done.informativeText = "已切到新 vault: \(dest.path)"
            done.runModal()
        } catch {
            let e = NSAlert(error: error)
            e.messageText = "Restore 失败"
            e.runModal()
        }
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

// MARK: - P3-C3: 5 步骤 stage 进度状态

struct DreamStage: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case success(String)  // detail 文字（"done: 3 files"）
        case failed(String)
        case skipped          // 没候选时 consolidate 跳过
    }
    let key: String       // "gather" / "consolidate" / "decay" / "persist" / "commit"
    let title: String     // 用户看的标题
    let system: String    // SF Symbol
    var state: State

    var id: String { key }

    static let allStages: [DreamStage] = [
        DreamStage(key: "gather",      title: "Gather",      system: "tray.and.arrow.down.fill", state: .pending),
        DreamStage(key: "consolidate", title: "Consolidate", system: "wand.and.stars",           state: .pending),
        DreamStage(key: "decay",       title: "Decay",       system: "hourglass",                state: .pending),
        DreamStage(key: "persist",     title: "Persist",     system: "square.and.arrow.down.fill", state: .pending),
        DreamStage(key: "commit",      title: "Commit",      system: "checkmark.seal.fill",      state: .pending),
    ]
}

// MARK: - AppModel（@MainActor ObservableObject）
//
// 三个面板共享状态：
// - vaultRoot: 当前 vault 路径（来自 --vault 或 DREAMVAULT_VAULT）
// - selectedFile: 当前选中的 vault 内文件（绝对路径）
// - lastReport: 最近一次 dream-run 的 DreamCycle.Outcome（nil 表示还没跑过）
// - status: 实时 vault 状态（raw 候选数 / ledger 三态 / 矛盾数 / 最近 report 路径）

@MainActor
public final class AppModel: ObservableObject {
    @Published var vaultRoot: URL
    @Published var selectedFile: URL? = nil
    @Published var lastOutcome: DreamCycle.Outcome? = nil
    @Published var lastError: String? = nil
    @Published var isRunning: Bool = false
    @Published var status: VaultStatus = .init()
    @Published var reportPath: String? = nil
    @Published var logLines: [String] = []
    /// P3-C3: 5 步 stage 进度（gather / consolidate / decay / persist / commit）。
    /// 每步独立状态：pending / running / success(detail) / failed(detail) / skipped。
    @Published var dreamStages: [DreamStage] = DreamStage.allStages
    /// P3-T1: 暴露 ledger 给 ConflictResolutionView（行内裁决读 + 写回）
    @Published var ledger: Ledger = .init()
    // T1 起 EditorState 接管 buffer / dirty 状态；保留 @Published 占位以兼容
    // 其他可能直接读这两个字段的视图代码（实际 EditorPane 自己用 EditorState）
    @Published var textEditorContent: String = ""
    @Published var textEditorDirty: Bool = false
    // P8: 预算快照（Dream tab 顶部 + Budget tab 详细表都读这个）
    @Published var budgetSnapshot: BudgetSnapshot? = nil
    /// P9c-P0-2: Reinforcer 实例（被 EditorPane / SearchSheet / Consolidator 调用）。
    /// switchVault 时重建。lazy 因为 init 阶段 vaultRoot 已被设好。
    private(set) var reinforcer: Reinforcer
    /// BudgetSnapshot 是从 BudgetManager 拉出来的不可变快照（避免 @MainActor 跨 context 泄漏）
    struct BudgetSnapshot: Equatable {
        var todayCount: Int
        var maxCallsPerDay: Int
        var monthCost: Double
        var monthlyBudgetUSD: Double
        var isOverBudget: Bool
    }

    /// GUI 模式默认 vault 路径解析顺序（最高优先在前）：
    /// 1. init(vault:) 显式传入
    /// 2. DreamEntry.resolveInitialVault() 统一入口（--vault / env / Settings / default）
    init(vault: URL? = nil) {
        let defaultPath = vault ?? DreamEntry.resolveInitialVault()
        self.vaultRoot = defaultPath
        self.reinforcer = Reinforcer(vaultRoot: defaultPath)
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
        // P9c-P0-2: 切 vault → 重建 reinforcer（旧 ledger 路径已变）
        self.reinforcer = Reinforcer(vaultRoot: url)
        refreshStatus()
    }

    func refreshStatus() {
        status = VaultStatus.load(from: vaultRoot)
        ledger = Persister.loadLedger(vaultRoot: vaultRoot)  // P3-T1
        refreshBudget()
    }

    /// P8: 从 BudgetManager 拉出快照（独立持久状态文件 .dream/budget-*.json）
    /// 这样 GUI 重启后状态不丢
    func refreshBudget() {
        let settings = DreamSettings.load()
        let resolved = ResolvedDreamRuntimeConfig.resolve(settings: settings)
        let budget = BudgetManager(config: resolved.budget, vaultRoot: vaultRoot)
        let snap = BudgetSnapshot(
            todayCount: budget.todayCount,
            maxCallsPerDay: resolved.budget.maxCallsPerDay,
            monthCost: budget.monthCost,
            monthlyBudgetUSD: resolved.budget.monthlyBudgetUSD,
            isOverBudget: !budget.canProceed(estimatedOutputTokens: 0, modelHint: "unknown")
        )
        self.budgetSnapshot = snap
    }

    /// 重置 stages 到初始 pending 状态
    private func resetDreamStages() {
        dreamStages = DreamStage.allStages
    }

    /// 把 DreamCycle onStage 字符串映射到对应 stage 状态
    private func handleStageEvent(_ event: String) {
        // event 形如 "gather" / "gather done: 3 files" / "persist failed: ..."
        let key: String
        if event.hasPrefix("link") { key = "consolidate" }  // link 是 consolidate 的一部分
        else if event.hasPrefix("gather") { key = "gather" }
        else if event.hasPrefix("consolidate") { key = "consolidate" }
        else if event.hasPrefix("decay") { key = "decay" }
        else if event.hasPrefix("persist") { key = "persist" }
        else if event.hasPrefix("commit") { key = "commit" }
        else { return }

        if let idx = dreamStages.firstIndex(where: { $0.key == key }) {
            if event.contains("failed:") {
                dreamStages[idx].state = .failed(event)
            } else if event.contains(" done:") {
                dreamStages[idx].state = .success(event)
            } else {
                dreamStages[idx].state = .running
            }
        }
    }

    /// GUI 内的 Run Dream。直接调 DreamCycle，不开子进程
    /// P2-1: 菜单栏 Recent Memory 点击 — 跳到该记忆的源文件
    func openMemory(_ mem: Memory) {
        guard let first = mem.sources.first else { return }
        let url = vaultRoot.appendingPathComponent(first.file)
        selectedFile = url
    }

    func runDream() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        resetDreamStages()
        logLines.append("--- dream 开始 \(Self.stamp(Date())) ---")
        defer { isRunning = false }
        do {
            // P4-T2: 改用 ResolvedDreamRuntimeConfig 5 层 priority merge
            // （CLI / vault config / UserDefaults / env / default）
            // 替代 GlobalOptions().llmProvider() 单层 env 路径
            let runtime = try await GlobalOptions(vault: vaultRoot.path).runtimeContext()
            let resolved = runtime.resolved
            logLines.append("config: provider=\(resolved.llm.provider.rawValue) model=\(resolved.llm.model) 3Step=\(resolved.consolidation.useThreeStepCoT) conc=\(resolved.consolidation.concurrency)")

            // P4-T4: budget 检查
            let budget = runtime.budgetManager
            guard budget.canProceed() else {
                throw DreamCycle.DreamError.consolidateFailed(underlying:
                    NSError(domain: "Budget", code: 1,
                           userInfo: [NSLocalizedDescriptionKey:
                            "LLM 预算已耗尽（今日 \(budget.todayCount) 次 / $\(String(format: "%.2f", budget.monthCost))）。调大 Budget 或等明天。"]))
            }

            let git = GitRunner(repoRoot: vaultRoot)
            let cycle = DreamCycle(
                vaultRoot: vaultRoot,
                llm: runtime.provider,
                git: git,
                config: runtime.dreamConfig
            )
            let outcome = try await cycle.runOnce { [weak self] event in
                Task { @MainActor in
                    self?.handleStageEvent(event)
                    self?.logLines.append("[\(Self.stamp(Date()))] \(event)")
                }
            }
            // 全部 success 后把还没显式标 "done" 的 stage 标 success
            for i in dreamStages.indices where dreamStages[i].state == .running {
                dreamStages[i].state = .success("done")
            }
            lastOutcome = outcome
            reportPath = outcome.reportPath
            logLines.append("gathered=\(outcome.gatheredCount) accepted=\(outcome.acceptedCount) committed=\(outcome.committed)")
            refreshStatus()
            // P2-1: dream 跑完发通知 + 切 hasNew
            let topExcerpt = ledger.memories
                .filter { $0.status == .durable }
                .sorted { $0.lastAccess > $1.lastAccess }
                .first?.text
            MenuBarController.shared.notifyDreamFinished(
                accepted: outcome.acceptedCount,
                archived: outcome.archivedCount,
                topExcerpt: topExcerpt
            )
        } catch let e as DreamCycle.DreamError {
            // P8: 撞上 userDirtyWorkspace，按用户策略决定 auto-commit / 报错 / 弹窗
            if case .userDirtyWorkspace = e {
                handleUserDirty()
            } else {
                lastError = String(describing: e)
                logLines.append("FAIL: \(e)")
            }
        } catch {
            lastError = error.localizedDescription
            logLines.append("FAIL: \(error.localizedDescription)")
        }
    }

    /// P8: 处理 raw/ dirty 三选项
    /// - autoCommit：静默 commit（不打扰用户）
    /// - prompt：弹 NSAlert 三选项，让用户当场选；选后写进 UserDefaults 永久记忆
    /// - skip：把错误显示到 lastError，让用户手动处理
    private func handleUserDirty() {
        let strategy = UserDirtyStrategy.load() ?? .prompt
        logLines.append("userDirty: strategy=\(strategy.rawValue)")
        switch strategy {
        case .autoCommit:
            applyAutoCommit()
        case .prompt:
            // 弹 alert（MainActor 上下文）
            let alert = NSAlert()
            alert.messageText = "Vault 有未提交的改动"
            alert.informativeText = "检测到 raw/ 等非引擎路径有未 commit 改动。Dream 需要明确的工作区状态才能跑。\n\n请选择这次怎么处理："
            alert.addButton(withTitle: "Auto-Commit (记住选择)")
            alert.addButton(withTitle: "Skip This Run (报错给我)")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                UserDirtyStrategy.save(.autoCommit)
                applyAutoCommit()
            case .alertSecondButtonReturn:
                UserDirtyStrategy.save(.skip)
                lastError = "vault 有 raw/ 改动未 commit。Settings 改策略或手动 commit 后再跑。"
                logLines.append("userDirty: skipped (user picked skip)")
            default:
                logLines.append("userDirty: cancelled")
            }
        case .skip:
            lastError = "vault 有 raw/ 改动未 commit。Settings 改策略或手动 commit 后再跑。"
            logLines.append("userDirty: skipped (per saved strategy)")
        }
    }

    private func applyAutoCommit() {
        let git = GitRunner(repoRoot: vaultRoot)
        do {
            if let head = try git.autoCommitUserChanges() {
                logLines.append("auto-commit OK: \(head.prefix(7))")
                // 重新跑 dream（成功 auto-commit 之后 dream 应该 OK）
                Task { await self.runDream() }
            } else {
                logLines.append("auto-commit: nothing to commit")
            }
        } catch {
            lastError = "auto-commit 失败: \(error.localizedDescription)"
            logLines.append("auto-commit failed: \(error.localizedDescription)")
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

    // MARK: - P9: Rollback 二次确认
    //
    // 之前 Rollback 按钮一键就 revert 上次 dream，误触即丢当晚成果。
    // P9 修复：先弹 confirmationDialog 列出"将被回滚的 commit 内容"，
    // 用户确认后才真执行。
    /// nil = 不显示 dialog；非 nil = 显示并等待用户点
    @Published var rollbackConfirmation: GitRunner.LastCommitSummary? = nil

    /// 准备 rollback 确认（用户点 Rollback 按钮调用此方法）
    func requestRollback() {
        let git = GitRunner(repoRoot: vaultRoot)
        do {
            rollbackConfirmation = try git.lastCommitSummary()
        } catch {
            lastError = "rollback 准备失败: \(error.localizedDescription)"
            logLines.append("rollback 准备失败: \(error.localizedDescription)")
        }
    }

    /// 取消 rollback（用户在 dialog 选了 Cancel）
    func cancelRollback() {
        rollbackConfirmation = nil
        logLines.append("rollback cancelled by user")
    }

    /// 确认 rollback（在 dialog 选了 Confirm）
    func confirmRollback() {
        rollbackConfirmation = nil
        rollback()
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

        // raw 候选（P3-T5 fix: 用 Gatherer.parseFrontmatter 替代 .contains("processed: false") 全文扫描）
        // 老逻辑：读全文 + .contains("processed: false")，对每个 .md 都读几十 KB 到 MB。
        // 新逻辑：复用 Gatherer 已有的 parseFrontmatter + 同样的"显式 false 必收 / 显式 true 跳过 /
        //  无 frontmatter 保守按未处理" 三分支语义，只解析 frontmatter 头部（O(几百字节)）
        // 而非全文。
        let rawDir = vaultRoot.appendingPathComponent("raw")
        if fm.fileExists(atPath: rawDir.path) {
            let processed = Gatherer.loadProcessedRegistry(vaultRoot: vaultRoot)
            let files = (try? fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)) ?? []
            s.rawCandidateCount = files.filter { f in
                let rel = "raw/\(f.lastPathComponent)"
                if processed.contains(rel) { return false }
                guard let content = try? String(contentsOf: f, encoding: .utf8) else { return false }
                return Gatherer.shouldProcessRaw(content: content)
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
