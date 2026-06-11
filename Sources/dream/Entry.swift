import Foundation
import SwiftUI
import AppKit
import DreamEngine

// MARK: - dream 二进制顶层入口
//
// 路由：
//   argv[1] == "app"  → 启动 SwiftUI GUI（DreamVaultApp.main()）
//   其他 / 空           → 走 CLI（DreamCLI.main()）
//
// 用 @main 在这里 —— SwiftUI 那边不再写 @main。

@main
struct DreamEntry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "app" {
            // SwiftUI 路径：必须比 NSApplication init 早设这两个 UserDefaults，
            // 否则 CFPrefsD 会在 applicationWillFinishLaunching 之前加载默认 true，
            // 卡在 "Restoring windows" 然后 0 窗出来。
            UserDefaults.standard.set(false, forKey: "ApplePersistenceIgnoreState")
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
            UserDefaults.standard.synchronize()
            DreamVaultApp.main()
        } else {
            // CLI 路径：DreamCLI.main() 是 async，起 Task 跑，进程挂起等结果
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                let code = await DreamCLI.main()
                Foundation.exit(code)
            }
            // 死等 —— DreamCLI.main() 内部调 Foundation.exit() 终止进程
            sema.wait()
        }
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
        let vaultRoot = (ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.dreamvault", isDirectory: true)
        try? RawReadonlyGuard.makeReadonly(vaultRoot: vaultRoot)
        FileHandle.standardError.write(Data("[DreamVault] RawReadonlyGuard applied at \(vaultRoot.path)/raw\n".utf8))
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

    var body: some Scene {
        WindowGroup("DreamVault") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }  // 去掉默认 New File
        }
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
    @Published var textEditorContent: String = ""
    @Published var textEditorDirty: Bool = false

    /// GUI 模式默认 vault 路径 = ~/.dreamvault，可被 --vault 覆盖
    init(vault: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"]
        let defaultPath = vault
            ?? (env.map { URL(fileURLWithPath: $0, isDirectory: true) })
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.dreamvault", isDirectory: true)
        self.vaultRoot = defaultPath
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
