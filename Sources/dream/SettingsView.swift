import SwiftUI
import AppKit
import DreamEngine

/// P3-T7: 原生 macOS Settings 面板。
/// 通过 .commands { Settings { SettingsView() } } 在 DreamVault 菜单下挂 "Settings..." (Cmd-,)
public struct SettingsView: View {
    @State private var settings: DreamSettings = .load()
    /// 加载时的初始快照，用来判断"是否被改过"
    @State private var initialSettings: DreamSettings = .load()
    @State private var saveStatus: SaveStatus = .idle
    /// 上次保存时间；用来标"Saved 3s ago"
    @State private var lastSavedAt: Date? = nil
    /// P1-1: 当前 vault 的 durable 计数, 用于 100+ banner
    @State private var durableCount: Int = 0

    /// P1-1: 接收 vaultPath, 打开时读 ledger 算 durable count.
    /// 拿不到 path (没初始化 vault) → 0, banner 不显示.
    public init(vaultPath: String = "") {
        self._durableCount = State(initialValue: 0)
        // 立即读 ledger
        if !vaultPath.isEmpty {
            let url = URL(fileURLWithPath: vaultPath, isDirectory: true)
            if let ledger = try? Persister.loadLedger(vaultRoot: url) {
                self._durableCount = State(initialValue:
                    ledger.memories.filter { $0.status == .durable }.count)
            }
        }
    }

    /// P1-1: banner 阈值 = 100 (经验值, 100 条以下矛盾检测 LLM 容易跑全, 100+ 走 3 段能防更多 fabricated)
    static let threeStepBannerThreshold = 100

    /// P1-1: 是否显示 3-Step CoT 推 banner
    /// 条件: durable >= 100 AND useThreeStepCoT == false
    static func shouldShowThreeStepBanner(durableCount: Int, useThreeStepCoT: Bool) -> Bool {
        durableCount >= threeStepBannerThreshold && !useThreeStepCoT
    }

    /// 计算当前 in-memory settings 跟 disk 上的 initial 是否一致
    private var hasUnsavedChanges: Bool {
        settings != initialSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                llmTab
                    .tabItem { Label("LLM", systemImage: "cpu") }
                budgetTab
                    .tabItem { Label("Budget", systemImage: "dollarsign.circle") }
                dreamTab
                    .tabItem { Label("Dream", systemImage: "moon.stars") }
                privacyTab
                    .tabItem { Label("Privacy", systemImage: "lock.shield") }
            }
            .frame(width: 520, height: 410)

            // P8 修复：所有 tab 都有 Save 按钮和状态条
            // （之前只有 Dream tab 有 Save，其他 tab 改完不存，UI 也不会告诉用户）
            Divider()
            bottomBar
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 8) {
            // 状态指示
            Group {
                if hasUnsavedChanges {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.orange)
                        .font(.caption)
                } else if case .saved(let date) = saveStatus {
                    Label("Saved \(Self.relative(date))", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Label("No pending changes", systemImage: "circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            Spacer()

            // 临时错误显示
            if case .error(let msg) = saveStatus {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button("Revert") {
                settings = initialSettings
            }
            .disabled(!hasUnsavedChanges)
            .help("Discard unsaved changes")

            Button("Save") {
                applySettings()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasUnsavedChanges)
            .help("Save all tab changes to UserDefaults")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// 保存到 UserDefaults + 更新 initial 快照
    private func applySettings() {
        do {
            settings.save()
            initialSettings = settings
            lastSavedAt = Date()
            saveStatus = .saved(lastSavedAt!)
            // 2s 后 idle
            let savedAt = lastSavedAt!
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let current = lastSavedAt, current == savedAt {
                    saveStatus = .idle
                }
            }
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    enum SaveStatus: Equatable {
        case idle
        case saved(Date)
        case error(String)
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $colorSchemeMode) {
                    ForEach(ColorSchemeController.Mode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: colorSchemeMode) { newMode in
                    ColorSchemeController.shared.mode = newMode
                }
                Text("默认跟系统；可强制 Light / Dark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Vault Location") {
                HStack {
                    Text(settings.vaultPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose…") { pickVaultPath() }
                }
                Text("Vault 是 git 仓库，dream 周期的事务边界。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Nightly Dream (launchd)") {
                Toggle("Enable nightly dream at 3:00 AM", isOn: $settings.nightlyDreamEnabled)
                    .onChange(of: settings.nightlyDreamEnabled) { _ in
                        // P3-T9 钩子：调 SMAppService / launchd
                        // 当前实现：写 log；真实注册留给 follow-up commit
                        NightlyDreamScheduler.shared
                            .setEnabled(settings.nightlyDreamEnabled, vaultPath: settings.vaultPath)
                    }
                Text("启用后会注册一个 launchd job 每天 3:00 跑 dream run。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// P5-T2: 双向绑定 ColorSchemeController.mode
    @State private var colorSchemeMode: ColorSchemeController.Mode = ColorSchemeController.shared.mode

    // MARK: - LLM

    @ViewBuilder
    private var llmTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $settings.llmChoice) {
                    ForEach(DreamSettings.LLMChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.menu)
            }

            if settings.llmChoice == .ollama {
                Section("Ollama") {
                    TextField("Base URL", text: $settings.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    Button("Test Connection") { testOllamaConnection() }
                    if let s = ollamaTestStatus {
                        Text(s)
                            .font(.caption)
                            .foregroundColor(ollamaTestStatusColor)
                    }
                    Text("默认 http://127.0.0.1:11434/v1 (OpenAI 兼容)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.llmChoice == .openaiCompat {
                Section("OpenAI-Compatible (云端)") {
                    TextField("Base URL", text: $settings.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    // P4-T3: API key 走 Keychain，不显示在 UI
                    HStack {
                        if keychainHasKey {
                            Text("✓ API key 已存到 Keychain")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("⚠ 未设置 API key")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Button("Set API Key…") { setAPIKey() }
                        if keychainHasKey {
                            Button("Clear") { clearAPIKey() }
                        }
                    }
                    Button("Test Connection") { testOllamaConnection() }
                    if let s = ollamaTestStatus {
                        Text(s)
                            .font(.caption)
                            .foregroundColor(ollamaTestStatusColor)
                    }
                    Text("Keychain item: com.OmixNet.dreamvault.openai-key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @State private var keychainHasKey: Bool = {
        let key = Keychain.loadIfPresent(itemName: "com.OmixNet.dreamvault.openai-key")
        return key != nil && !key!.isEmpty
    }()

    private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API Key"
        alert.informativeText = "Stored in macOS Keychain. Never written to vault config or git."
        let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = "sk-..."
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let s = textField.stringValue
            if !s.isEmpty {
                do {
                    try Keychain.save(s, itemName: "com.OmixNet.dreamvault.openai-key")
                    keychainHasKey = true
                } catch {
                    FileHandle.standardError.write(Data(
                        "[Settings] Keychain save failed: \(error.localizedDescription)\n".utf8))
                }
            }
        }
    }

    private func clearAPIKey() {
        try? Keychain.delete(itemName: "com.OmixNet.dreamvault.openai-key")
        keychainHasKey = false
    }

    @State private var ollamaTestStatus: String? = nil
    @State private var ollamaTestStatusColor: Color = .secondary

    private func testOllamaConnection() {
        let provider = settings.makeLLMProvider()
        if let ollama = provider as? OllamaProvider {
            Task {
                do {
                    let response = try await ollama.complete(
                        system: "You are a connectivity test.",
                        user: "Reply with the single word: PONG"
                    )
                    await MainActor.run {
                        ollamaTestStatus = "✓ \(response.prefix(50))"
                        ollamaTestStatusColor = .green
                    }
                } catch {
                    await MainActor.run {
                        ollamaTestStatus = "✗ \(error.localizedDescription)"
                        ollamaTestStatusColor = .red
                    }
                }
            }
        } else {
            ollamaTestStatus = "✗ 当前 provider 不是 Ollama"
            ollamaTestStatusColor = .red
        }
    }

    // MARK: - Budget

    @ViewBuilder
    private var budgetTab: some View {
        Form {
            // P8: 详细预算状态（Dream tab 顶部只显示紧凑版）
            Section("当前使用 (Current Usage)") {
                if let s = currentBudgetSnapshot {
                    LabeledContent("Today") {
                        Text("\(s.todayCount) / \(s.maxCallsPerDay == 0 ? "∞" : "\(s.maxCallsPerDay)") calls")
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("Month") {
                        Text(String(format: "$%.4f", s.monthCost) + " / " +
                             (s.monthlyBudgetUSD == 0 ? "∞" : String(format: "$%.2f", s.monthlyBudgetUSD)))
                            .font(.system(.body, design: .monospaced))
                    }
                    if s.isOverBudget {
                        Label("Over budget — Run Dream will skip", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    } else if s.monthlyBudgetUSD > 0 && s.monthCost > s.monthlyBudgetUSD * 0.8 {
                        Label("Approaching limit (>80%)", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                    Text("Source: <vault>/.dream/budget-YYYY-MM-DD.json / budget-YYYY-MM.json")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Run a dream to populate budget usage.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Local (Ollama)") {
                LabeledContent("Cost") { Text("Free (本地推理)") }
                LabeledContent("Daily cap") { Text("Unlimited (本地无费用)") }
                Text("本地 LLM 无 API 费，但仍建议设并发上限（见 Dream tab）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Cloud (OpenAI-Compatible)") {
                Stepper(value: $settings.maxCallsPerDay, in: 0...10000) {
                    Text("Daily cap: \(settings.maxCallsPerDay)")
                        .font(.system(.body, design: .monospaced))
                }
                Text("0 = 不限")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Monthly budget:")
                    TextField("USD", value: $settings.monthlyBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("USD")
                }
                Text("0 = 不限；超 \(settings.monthlyBudgetUSD) 美元/月自动 skip 当次 run。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Per-run limits") {
                Stepper(value: $settings.maxRawFilesPerRun, in: 1...200) {
                    Text("Max raw files per run: \(settings.maxRawFilesPerRun)")
                }
                Text("超过会先报 warning + 跳过 oversized 文件")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// P8: 拉一次最新 budget 快照（每次 tab 出现都拉一下，简单的刷新机制）
    @State private var currentBudgetSnapshot: AppModel.BudgetSnapshot? = nil
    private var budgetRefreshTrigger: some View {
        // 用 .onAppear 触发
        Group {
            EmptyView()
        }
    }

    @ViewBuilder
    private var privacyTab: some View {
        Form {
            Section("Redaction") {
                Toggle("Redact PII before LLM call (recommended)",
                       isOn: $settings.redactBeforeConsolidate)
                Text("邮箱 / 手机 / 身份证 / 信用卡 / API key 等会被 [REDACTED_XXX] 替换后再发 LLM")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Cloud Privacy") {
                Toggle("Allow sending raw 摘要 to cloud provider",
                       isOn: $settings.allowCloudSendRawSummary)
                if settings.llmChoice != .ollama {
                    Text("⚠ 当前 provider 是云端，raw 摘要会发到 \(settings.ollamaBaseURL)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text("强烈建议关。Ollama 本地不受影响。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Diagnostics") {
                Toggle("Include vault path in export",
                       isOn: $settings.diagnosticsIncludePath)
                Toggle("Include log lines in export",
                       isOn: $settings.diagnosticsIncludeLogs)
                Text("Export Diagnostics 写到桌面时是否包含敏感字段")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Dream

    @ViewBuilder
    private var dreamTab: some View {
        Form {
            // P1-1: durable 100+ 时推 3-Step CoT banner
            // 只在 (durable >= 100) AND (没开 3-Step) 时显示
            if Self.shouldShowThreeStepBanner(durableCount: durableCount,
                                               useThreeStepCoT: settings.useThreeStepCoT) {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("You have \(durableCount) durable memories")
                                .font(.subheadline).bold()
                            Text("With 100+ memories, 3-Step CoT (analyze → generate → verify) reduces hallucination significantly. Slows nightly run ~3× but catches LLM-generated fake excerpts.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button {
                                    settings.useThreeStepCoT = true
                                } label: {
                                    Label("Enable 3-Step CoT", systemImage: "checkmark.shield")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button("Maybe later") {
                                    // Dismiss for this session; banner will re-appear next time
                                    // (P1-1 简化: 不持久化 dismiss, 用户下次开 Settings 仍看到)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .foregroundColor(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.12))
                    .cornerRadius(6)
                } header: {
                    Text("Recommendation")
                }
            }

            Section("Consolidation") {
                Toggle("3-Step CoT (analyze → generate → verify)",
                       isOn: $settings.useThreeStepCoT)
                Text("3-Step 防幻觉更好但慢 3 倍。2-Step 适合 mock / 极快模型。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Concurrency:")
                    Stepper(value: $settings.consolidationConcurrency, in: 1...4) {
                        Text("\(settings.consolidationConcurrency)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 30)
                    }
                }
                Text("本地 Ollama 推荐 2。4 + 大模型容易 OOM/超时。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickVaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.directoryURL = URL(fileURLWithPath: settings.vaultPath,
                                  isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            // 改完不立即 save；P8 改：让用户按 Save 按钮或者被其他改动触发
            settings.vaultPath = url.path
        }
    }
}
