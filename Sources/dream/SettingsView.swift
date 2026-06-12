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
            dreamTab
                .tabItem { Label("Dream", systemImage: "moon.stars") }
        }
        .frame(width: 480, height: 380)
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
        }
        .formStyle(.grouped)
        .padding()
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
