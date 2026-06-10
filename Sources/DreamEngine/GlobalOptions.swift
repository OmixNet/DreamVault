import Foundation

// MARK: - GlobalOptions（dream CLI 共享的全局参数）
//
// 放在 DreamEngine 库中是因为 Tests target 需要 import 来测参数解析。
// dream CLI 自己的 main.swift 也 import 用。
public struct GlobalOptions {
    public var vault: String?
    public var llm: String?
    public var verbose: Bool = false

    /// 从 args 列表里抽走全局 flag（inout 修改原数组）
    public static func parse(from args: inout [String]) -> GlobalOptions {
        var o = GlobalOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--vault":
                if i + 1 < args.count {
                    o.vault = args[i + 1]
                    args.removeSubrange(i...i + 1)
                } else { i += 1 }
            case "--llm":
                if i + 1 < args.count {
                    o.llm = args[i + 1]
                    args.removeSubrange(i...i + 1)
                } else { i += 1 }
            case "--verbose", "-v":
                o.verbose = true
                args.remove(at: i)
            default:
                i += 1
            }
        }
        return o
    }

    /// 解析 --vault，未指定则用 $DREAMVAULT_VAULT 或 $HOME/.dreamvault
    public func vaultURL() -> URL {
        let path = vault
            ?? ProcessInfo.processInfo.environment["DREAMVAULT_VAULT"]
            ?? "\(NSHomeDirectory())/.dreamvault"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    /// 决定 LLM provider。优先 --llm 覆盖，其次 DREAMVAULT_LLM 环境变量
    public func llmProvider() -> LLMProvider {
        let env = ProcessInfo.processInfo
        if let which = llm ?? env.environment["DREAMVAULT_LLM"], !which.isEmpty {
            switch which.lowercased() {
            case "ollama":
                let base = env.environment["OLLAMA_BASE_URL"] ?? "http://127.0.0.1:11434"
                let model = env.environment["OLLAMA_MODEL"] ?? "llama3.1"
                return OllamaProvider(
                    baseURL: URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!,
                    model: model
                )
            case "mock", "":
                return MockLLMProvider()
            default:
                FileHandle.standardError.write(Data(
                    "dream: 未知 --llm '\(which)'，回退 MockLLMProvider\n".utf8))
                return MockLLMProvider()
            }
        }
        return LLMFactory.fromEnvironment()
    }

    /// 显式构造（测试用）
    public init(vault: String? = nil, llm: String? = nil, verbose: Bool = false) {
        self.vault = vault
        self.llm = llm
        self.verbose = verbose
    }
}
