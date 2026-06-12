import SwiftUI
import AppKit
import DreamEngine

/// P7-T1: 首次启动引导 sheet。
///
/// 触发条件：UserDefaults["DreamVault.didShowWelcome"] == nil。
/// 三步：
///   1. 选 vault 目录（NSOpenPanel）—— 也支持"以后再说"
///   2. 选 LLM provider + baseURL + model（默认 .ollama + http://127.0.0.1:11434）
///   3. "Ready" — 写 UserDefaults didShowWelcome=true + 打开 main window
///
/// "Skip" 按钮任意步可点（写 didShowWelcome=true 但不配）
@MainActor
public struct FirstRunWelcomeView: View {
    @State private var step: Int = 0
    @State private var selectedVaultPath: String = DreamSettings.default.vaultPath
    @State private var llmChoice: DreamSettings.LLMChoice = .ollama
    @State private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @State private var ollamaModel: String = "llama3.1"
    @State private var testStatus: String? = nil
    @State private var testOK: Bool = false
    let onComplete: (Bool) -> Void  // bool: 是否真的配了 vault + LLM

    public init(onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete
    }

    public static var didShowWelcomeKey: String { FirstRunTracker.didShowWelcomeKey }
    public static func shouldShow() -> Bool { FirstRunTracker.shouldShow() }

    public var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Welcome to DreamVault")
                        .font(.title2).bold()
                    Text("3 步快速开始")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .background(.bar)

            Divider()

            // content per step
            Group {
                switch step {
                case 0: vaultStep
                case 1: llmStep
                case 2: readyStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

            Divider()

            // footer
            HStack {
                Button("Skip") { finish(configured: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                if step < 2 {
                    Button("Next") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(step == 0 && selectedVaultPath.isEmpty)
                } else {
                    Button("Done") { finish(configured: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 380)
    }

    @ViewBuilder
    private var vaultStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step 1 / 3 — Vault")
                .font(.headline)
            Text("Vault 是 git 仓库，dream 周期的事务边界。所有 raw 文件、wiki、ledger 都存在这里。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(selectedVaultPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Choose…") { pickVault() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("或者：")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Create new vault at \(NSHomeDirectory())/.dreamvault") {
                    createNewVault()
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step 2 / 3 — LLM")
                .font(.headline)
            Text("dream 周期需要 LLM 提炼 raw 笔记。本地 Ollama 零成本；云端需 API key。")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Provider", selection: $llmChoice) {
                ForEach(DreamSettings.LLMChoice.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.menu)

            if llmChoice != .mock {
                TextField("Base URL", text: $ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
            }

            if llmChoice != .mock {
                HStack {
                    Button("Test Connection") { testConnection() }
                    if let s = testStatus {
                        Text(s)
                            .font(.caption)
                            .foregroundColor(testOK ? .green : .red)
                    }
                }
            }
            Text("Settings → LLM 之后可改 + 设 API Key")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step 3 / 3 — Ready")
                .font(.headline)
            Text("设置已保存。Vault nightly dream 默认 3:00 AM（可在 Settings → General 关掉）。")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label(selectedVaultPath, systemImage: "folder")
                    .font(.system(.caption, design: .monospaced))
                Label("\(llmChoice.rawValue) — \(ollamaBaseURL)", systemImage: "cpu")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(4)

            Text("💡 把 raw 文件扔到 vault/raw/ 后点 DreamPanel 的 Run Dream 即可。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - actions

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        if panel.runModal() == .OK, let url = panel.url {
            selectedVaultPath = url.path
        }
    }

    private func createNewVault() {
        let newVault = URL(fileURLWithPath: NSHomeDirectory() + "/.dreamvault",
                           isDirectory: true)
        try? FileManager.default.createDirectory(at: newVault, withIntermediateDirectories: true)
        for sub in ["raw", "wiki/entities", "wiki/concepts", "wiki/syntheses", "wiki/archive", ".dream"] {
            try? FileManager.default.createDirectory(
                at: newVault.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
        // git init
        let git = GitRunner(repoRoot: newVault)
        _ = try? git.run(["init"])
        _ = try? git.run(["config", "user.email", "dream@dreamvault.local"])
        _ = try? git.run(["config", "user.name", "DreamVault"])
        selectedVaultPath = newVault.path
    }

    private func testConnection() {
        let base = URL(string: ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
        let provider = OllamaProvider(baseURL: base, model: ollamaModel)
        Task {
            do {
                _ = try await provider.complete(
                    system: "Connectivity test.",
                    user: "Reply: PONG"
                )
                await MainActor.run {
                    testStatus = "✓ connected"
                    testOK = true
                }
            } catch {
                await MainActor.run {
                    testStatus = "✗ \(error.localizedDescription.prefix(60))"
                    testOK = false
                }
            }
        }
    }

    private func finish(configured: Bool) {
        // 持久化
        FirstRunTracker.markShown()
        if configured {
            var s = DreamSettings.default
            s.vaultPath = selectedVaultPath
            s.llmChoice = llmChoice
            s.ollamaBaseURL = ollamaBaseURL
            s.ollamaModel = ollamaModel
            s.save()
        }
        onComplete(configured)
    }
}
