import SwiftUI
import AppKit
import DreamEngine

/// P3-T7: 原生 macOS Settings 面板。
/// 通过 .commands { Settings { SettingsView() } } 在 DreamVault 菜单下挂 "Settings..." (Cmd-,)
public struct SettingsView: View {
    @State private var settings: DreamSettings = .load()
    @State private var saveStatus: String? = nil  // 临时 toast

    public init() {}

    public var body: some View {
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
        .frame(width: 520, height: 460)
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        Form {
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

            HStack {
                Spacer()
                if let status = saveStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Button("Save") {
                    settings.save()
                    saveStatus = "Saved ✓"
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { saveStatus = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
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
            settings.vaultPath = url.path
            settings.save()
        }
    }
}
