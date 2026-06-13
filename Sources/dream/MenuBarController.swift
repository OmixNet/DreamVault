// P2-1: 菜单栏常驻 (完整版: status item + 6 菜单 + 子菜单 + 状态 icon + 通知)
import AppKit
import UserNotifications
import DreamEngine

/// 菜单栏常驻控制器. AppKit NSStatusItem + NSMenu 模式 (非 SwiftUI).
///
/// 状态: 3 个 SF Symbol 切换
///   - idle:    "moon.stars" (默认)
///   - running: "moon.stars.fill" + 顺时针旋转动画 (P5 简化: 用 fill 静态)
///   - hasNew:  "moon.stars.fill" + 红色 badge (N accepted)
///
/// 菜单项 (从上到下):
///   - Open Vault
///   - Run Dream Now  (running 时 disabled)
///   - Recent Memory  ▸ (子菜单, last 8 条 durable)
///   - Search…        (弹 SearchSheet, 暂未实现 placeholder)
///   - Settings…      (NSApp.sendAction 触发 SwiftUI settings)
///   - ─────
///   - Quit DreamVault (NSApp.terminate)
///
/// 通知: dream 跑完时 AppModel 调 `notifyDreamFinished(accepted:)` 发本地通知.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    /// 单例 (P2-1: 菜单栏只一个 status item)
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    /// 引用 AppModel (从 AppDelegate / App 启动时注入)
    public weak var model: AppModel?

    // MARK: - 状态

    public enum IconState: Equatable {
        case idle
        case running
        case hasNew(Int)
    }

    private var currentState: IconState = .idle
    /// 通知授权状态 (启动后异步查询)
    private var notificationAuthorized: Bool = false

    // MARK: - 启动

    /// 在 MainView.onAppear 调一次 (idempotent, 多次调安全 — start 完就不再 setup)
    public func start(model: AppModel) {
        if statusItem != nil {
            // 已启动, 只更新 model 引用 (fallback window 可能拿到新 model)
            self.model = model
            return
        }
        self.model = model
        setupStatusItem()
        setupNotifications()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "moon.stars",
                                   accessibilityDescription: "DreamVault")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationAuthorized = granted
            }
        }
    }

    // MARK: - 菜单构建

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let m = model

        // 1. Open Vault
        let openVault = NSMenuItem(title: "Open Vault",
                                   action: #selector(menuOpenVault),
                                   keyEquivalent: "o")
        openVault.target = self
        openVault.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(openVault)

        // 2. Run Dream Now
        let runDream = NSMenuItem(title: "Run Dream Now",
                                  action: #selector(menuRunDream),
                                  keyEquivalent: "d")
        runDream.target = self
        runDream.keyEquivalentModifierMask = [.command, .shift]
        runDream.isEnabled = m.map { !$0.isRunning } ?? false
        menu.addItem(runDream)

        menu.addItem(.separator())

        // 3. Recent Memory (子菜单, last 8)
        let recent = NSMenuItem(title: "Recent Memory", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent Memory")
        submenu.autoenablesItems = false
        recent.submenu = submenu
        if let m = m {
            let durables = m.ledger.memories
                .filter { $0.status == .durable }
                .sorted { $0.lastAccess > $1.lastAccess }
                .prefix(8)
            if durables.isEmpty {
                let placeholder = NSMenuItem(title: "(no durable memories yet)",
                                              action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                submenu.addItem(placeholder)
            } else {
                for mem in durables {
                    let label = mem.text.count > 60
                        ? String(mem.text.prefix(60)) + "…"
                        : mem.text
                    let item = NSMenuItem(title: label,
                                          action: #selector(menuOpenMemory(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = mem.id
                    item.toolTip = mem.text
                    submenu.addItem(item)
                }
            }
        }
        menu.addItem(recent)

        // 4. Search…
        let search = NSMenuItem(title: "Search…", action: #selector(menuSearch),
                                keyEquivalent: "f")
        search.target = self
        search.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(search)

        // 4c. P2-3: Insert Wikilink
        let insertWL = NSMenuItem(title: "Insert Wikilink…",
                                  action: #selector(menuInsertWikilink),
                                  keyEquivalent: "k")
        insertWL.target = self
        insertWL.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(insertWL)

        // 4b. P2-2: Knowledge Graph
        let graph = NSMenuItem(title: "Knowledge Graph…",
                               action: #selector(menuGraph),
                               keyEquivalent: "g")
        graph.target = self
        graph.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(graph)

        menu.addItem(.separator())

        // 5. Settings…
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(menuSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // 6. Quit
        let quit = NSMenuItem(title: "Quit DreamVault",
                              action: #selector(menuQuit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 菜单 actions

    @objc private func menuOpenVault() {
        AppActions.openVault(model: model ?? AppModel())
    }

    @objc private func menuRunDream() {
        guard let m = model, !m.isRunning else { return }
        Task { @MainActor in await m.runDream() }
    }

    @objc private func menuOpenMemory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let m = model else { return }
        if let mem = m.ledger.memories.first(where: { $0.id == id }) {
            m.openMemory(mem)
        }
    }

    @objc private func menuSearch() {
        // P6: search 升级未做, 先弹 SearchSheet
        guard let m = model else { return }
        AppActions.openSearch(model: m)
    }

    @objc private func menuGraph() {
        guard let m = model else { return }
        AppActions.openGraph(model: m)
    }

    @objc private func menuInsertWikilink() {
        guard let m = model else { return }
        AppActions.insertWikilink(model: m)
    }

    @objc private func menuSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        // 每次弹出时重建 (recent memory 列表 / run dream enabled state 都会变)
        rebuildMenu()
    }

    // MARK: - 状态切换

    /// P2-1: 从 IconState 拿 SF Symbol name (logic-only, 可单测)
    public static func symbolName(for state: IconState) -> String {
        switch state {
        case .idle, .hasNew:
            return state == .idle ? "moon.stars" : "moon.stars.fill"
        case .running:
            return "moon.stars.fill"
        }
    }

    /// P2-1: 通知正文构造 (logic-only, 可单测)
    public static func notificationBody(accepted: Int, archived: Int, topExcerpt: String?) -> String {
        let prefix = "DreamVault: \(accepted) accepted, \(archived) archived"
        if let exc = topExcerpt, !exc.isEmpty {
            return "\(prefix)\n\(String(exc.prefix(80)))"
        }
        return "\(prefix)\nTap to open vault"
    }

    /// P2-1: app 在前台时本地通知仍然给用户明确反馈。
    public static func foregroundNotificationOptions() -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// P2-1: Recent Memory 菜单项 title 截断 (logic-only)
    public static func recentMemoryMenuTitle(_ text: String, maxLen: Int = 60) -> String {
        if text.count > maxLen {
            return String(text.prefix(maxLen)) + "…"
        }
        return text
    }

    public func setState(_ state: IconState) {
        currentState = state
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "moon.stars",
                                   accessibilityDescription: "DreamVault")
            button.image?.isTemplate = true
        case .running:
            button.image = NSImage(systemSymbolName: "moon.stars.fill",
                                   accessibilityDescription: "DreamVault running")
            button.image?.isTemplate = true
        case .hasNew(let n):
            button.image = NSImage(systemSymbolName: "moon.stars.fill",
                                   accessibilityDescription: "\(n) new memories")
            button.image?.isTemplate = true
            // 红色 badge: P2-1 简化用 image overlay
            let badge = NSTextField(labelWithString: "\(n)")
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = .systemRed
            badge.drawsBackground = true
            badge.alignment = .center
            badge.frame = NSRect(x: 12, y: -2, width: max(14, 8 + CGFloat(n > 9 ? 2 : 1) * 5), height: 12)
            badge.isBordered = false
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 6
            // 用 subview 叠加 (P2-1 简化: 不追求完美渲染, 实用为先)
            button.subviews.filter { $0 is NSTextField }.forEach { $0.removeFromSuperview() }
            button.addSubview(badge)
        }
    }

    // MARK: - 通知

    /// DreamCycle 跑完时调, 发本地通知 + 切状态到 hasNew
    public func notifyDreamFinished(accepted: Int, archived: Int, topExcerpt: String?) {
        if currentState != .running { return }  // 不是从 running 来的就不发
        setState(.hasNew(accepted))
        if !notificationAuthorized || accepted == 0 { return }
        let content = UNMutableNotificationContent()
        content.title = "DreamVault: \(accepted) accepted, \(archived) archived"
        if let exc = topExcerpt, !exc.isEmpty {
            content.body = String(exc.prefix(80))
        } else {
            content.body = "Tap to open vault"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: "dreamvault.dreamfinished",
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    /// dream 跑前调, 切到 running
    public func setRunning() {
        setState(.running)
    }

    /// dream 跑完切回 idle 或 hasNew
    public func clearRunning() {
        setState(.idle)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler:
                                       @escaping (UNNotificationPresentationOptions) -> Void) {
        // banner + sound (即使 app 在前台也弹)
        completionHandler(Self.foregroundNotificationOptions())
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        // 点通知 → 打开 vault 在 Finder
        if let m = model {
            NSWorkspace.shared.activateFileViewerSelecting([m.vaultRoot])
        }
        completionHandler()
    }
}
