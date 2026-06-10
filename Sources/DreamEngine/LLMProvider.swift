import Foundation

// MARK: - MockLLMProvider（测试与本地开发用）
//
// 行为由用户在构造时给定的 `handler` 决定。默认实现按调用方 prompt 文本里的关键词
// 决定返回 "YES"/"NO"/"CONFLICT"/"OK"，能直接驱动 Consolidator/ContradictionDetector
// 的闸门逻辑跑通端到端，无需真模型。
//
// 设计要点：
// - 默认实现不依赖任何外部进程/网络，单元测试无 flake
// - 调用方可以注入自己的 closure，模拟更复杂的 LLM 行为
// - 不会抛错（除了 handler 显式 throw）— 失败的语义靠返回错误文本表达
// - 是 class（非 struct）以便累积 `callCount` 而不打破 protocol 的非 mutating 要求
public final class MockLLMProvider: LLMProvider {
    public typealias Handler = (String, String) throws -> String  // (system, user) -> answer
    private let handler: Handler
    /// 记录调用次数，便于测试断言
    public private(set) var callCount: Int = 0

    public init(handler: @escaping Handler = MockLLMProvider.defaultHandler) {
        self.handler = handler
    }

    public func complete(system: String, user: String) async throws -> String {
        callCount += 1
        return try handler(system, user)
    }

    /// 默认 handler：扫 user prompt 找关键字，决定 YES/NO/CONFLICT/OK。
    /// 优先级：NO > CONFLICT > OK > YES。同 prompt 多关键字时取最高优先级。
    /// 这是为了让现有 `EngineTests.swift` 里手写的 Memory 能跑通：
    ///   "should use AppKit" → CONFLICT（被 existing "use SwiftUI" 触发）
    ///   "use jose" → 不命中 NO/CONFLICT → OK
    ///
    /// 注意：关键字要够"信号化"，不能太通用，否则会误伤端到端测试
    /// （"测试"是中文高频词，几乎任何 prompt 都命中 → OK → verify 失败）。
    /// 现状：仅 `appkit`（矛盾信号）和 `halluc`/`无依据`（幻觉信号）触发非 YES。
    /// OK 路径当前不命中，保留供未来扩展。
    public static let defaultHandler: Handler = { _, user in
        let lower = user.lowercased()
        if lower.contains("halluc") || lower.contains("无依据") { return "NO" }
        if lower.contains("appkit") { return "CONFLICT" }
        return "YES"
    }
}

// MARK: - OllamaProvider（本地 Ollama 真实模型）
//
// Ollama 在本机 `http://127.0.0.1:11434` 开一个 OpenAI 兼容的 /v1/chat/completions 端点。
// 我们不依赖外部 SDK，用 URLSession 直接打。
//
// 配置：构造时给 baseURL / model；不读环境变量，方便测试和上层注入。
// 网络错误/非 2xx → 抛 OllamaError，调用方决定是否回滚。
public struct OllamaProvider: LLMProvider {
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "llama3.1") {
        self.baseURL = baseURL
        self.model = model
    }

    public enum OllamaError: Error, CustomStringConvertible {
        case badStatus(Int, body: String)
        case malformedResponse(String)
        case transport(Error)

        public var description: String {
            switch self {
            case .badStatus(let code, let body):
                return "Ollama HTTP \(code): \(body)"
            case .malformedResponse(let s):
                return "Ollama 响应无法解析: \(s)"
            case .transport(let e):
                return "Ollama 传输错误: \(e.localizedDescription)"
            }
        }
    }

    public func complete(system: String, user: String) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.badStatus(http.statusCode, body: body)
        }
        // 解析 OpenAI 兼容响应：{ choices: [{ message: { content: "..." } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.malformedResponse(raw)
        }
        return content
    }
}

// MARK: - 工厂：从环境变量决定 provider
//
// `DREAMVAULT_LLM` 取值：
//   - "mock"     → MockLLMProvider（默认）
//   - "ollama"   → OllamaProvider（可选 OLLAMA_BASE_URL / OLLAMA_MODEL 覆盖）
public enum LLMFactory {
    public static func fromEnvironment() -> LLMProvider {
        let which = (ProcessInfo.processInfo.environment["DREAMVAULT_LLM"] ?? "mock").lowercased()
        switch which {
        case "ollama":
            let base = ProcessInfo.processInfo.environment["OLLAMA_BASE_URL"]
                ?? "http://127.0.0.1:11434"
            let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.1"
            return OllamaProvider(
                baseURL: URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!,
                model: model
            )
        case "mock", "":
            return MockLLMProvider()
        default:
            // 未知 → mock + stderr 警告，不让一次拼写错误炸掉整次 dream
            FileHandle.standardError.write(Data(
                "DREAMVAULT_LLM=\(which) 未知，回退到 MockLLMProvider\n".utf8))
            return MockLLMProvider()
        }
    }
}
