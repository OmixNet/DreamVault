import Foundation

// MARK: - OpenAICompatibleProvider（v0.5 P2c-2: 云端 OpenAI 兼容 provider）
//
// 覆盖 OpenRouter / SiliconFlow / 任何 OpenAI-compat /v1/chat/completions endpoint。
// 与 OllamaProvider 同协议但概念不同 — Ollama 是本地跑的 model server, OpenAI-compat
// 是云端 API (需要 Bearer auth)。拆成独立 type 让 makeProvider 路由清晰:
//
//   .ollama       → OllamaProvider (本地, 无 key)
//   .openaiCompat → OpenAICompatibleProvider (云端, Bearer auth)
//
// 设计取舍:
// - **不读 macOS Keychain**。DreamVault 保持纯引擎边界, key 由 DreamX Rust (PR 27)
//   从 Keychain 读 value, 通过 Command::env() 注入 `DREAMFORGE_LLM_API_KEY` 到
//   dream subprocess env。本 type 在 init 时一次性读 env var (不重读)。
// - **不做 streaming**。Consolidator / ContradictionDetector 等上游 caller 期望一次性
//   string response。streaming 后续 v0.6 PR 单独设计。
// - **不做 Anthropic / Gemini**。它们用不同协议 (Messages API / generateContent),
//   不是 OpenAI-compat。v0.6 单独 design, 避免在一个 PR 跨协议实现。
//
// 错误 (P2c-2 验收: stable 4 类):
// - `.missingAPIKey(hint)` — env var 空, 立即拒, 不发 HTTP 请求
// - `.badStatus(code, body)` — HTTP 非 2xx, 含 401 (auth failed) / 404 (model unavailable)
// - `.malformedResponse(raw)` — JSON 解析 fail 或缺 choices[0].message.content
// - `.transport(error)` — URLSession fail
//
// Security invariant: apiKey VALUE 永远不进入 description / log / 任何 string 输出。
public struct OpenAICompatibleProvider: LLMProvider, Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let timeoutSeconds: TimeInterval
    /// URLSession for HTTP. Defaults to `.shared` in production; tests inject
    /// a mock-backed session via `URLSession(configuration: .mockWithProtocol())`.
    /// URLSession is Sendable (Apple documents it as thread-safe) so no
    /// @unchecked needed here.
    public let session: URLSession

    /// env var name DreamX 注入 (PR 24 + PR 27). 只在 init 时读, 不运行时重读.
    public static let envVarName = "DREAMFORGE_LLM_API_KEY"

    public init(baseURL: URL,
                model: String,
                apiKey: String? = nil,
                timeoutSeconds: TimeInterval = 120,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        // API key resolution (init-time only):
        //   1. 显式传入的 apiKey (test 用, 优先)
        //   2. DREAMFORGE_LLM_API_KEY env var (DreamX Rust 注入)
        //   3. nil → complete() 时抛 .missingAPIKey
        //
        // 注意: 不读 macOS Keychain. DreamVault 是纯引擎, Keychain 是
        // DreamX (Tauri app) 的 security surface. PR 25 + PR 27 跨边界
        // 把 Keychain value 翻译成 env var, 本 type 只消费 env var.
        if let apiKey, !apiKey.isEmpty {
            self.apiKey = apiKey
        } else if let envKey = ProcessInfo.processInfo.environment[Self.envVarName],
                  !envKey.isEmpty {
            self.apiKey = envKey
        } else {
            self.apiKey = nil
        }
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    public enum OpenAICompatibleError: Error, CustomStringConvertible, LocalizedError {
        /// Stable "missing key" error. The hint string is generic — it tells
        /// the user how to set the key (env var) but NEVER contains the key
        /// value (it doesn't exist yet, but the invariant is locked).
        case missingAPIKey(String)
        /// HTTP non-2xx. Covers 401 (auth failed) / 403 (forbidden) /
        /// 404 (model unavailable) / 429 (rate limited) / 5xx (server error).
        /// Body is included for debugging but may contain provider-specific
        /// error structure — NOT the API key value.
        case badStatus(Int, body: String)
        /// Response body was 2xx but doesn't match the expected OpenAI-compat
        /// shape `{ choices: [{ message: { content: "..." } }] }`.
        case malformedResponse(String)
        /// URLSession-level error (DNS, TCP, TLS, timeout).
        case transport(Error)

        public var description: String {
            switch self {
            case .missingAPIKey(let hint):
                return "OpenAI-compatible missing API key: \(hint)"
            case .badStatus(let code, let body):
                // Stable prefix lets users grep for this category. Body is
                // included for debugging but may be truncated by the provider.
                return "OpenAI-compatible HTTP \(code): \(body)"
            case .malformedResponse(let s):
                return "OpenAI-compatible response malformed: \(s)"
            case .transport(let e):
                return "OpenAI-compatible transport error: \(e.localizedDescription)"
            }
        }

        public var errorDescription: String? { description }

        /// Stable category label used by error-format tests + (future) UI
        /// surface. NOT for stable error.message matching — DreamX consumes
        /// the full `description` string. This is for categorization only.
        public var category: String {
            switch self {
            case .missingAPIKey: return "missing-api-key"
            case .badStatus: return "bad-status"
            case .malformedResponse: return "malformed-response"
            case .transport: return "transport"
            }
        }
    }

    public func complete(system: String, user: String) async throws -> String {
        // Missing key check BEFORE making any HTTP request. Saves a network
        // round-trip and gives the user a clear, immediate error.
        guard let apiKey, !apiKey.isEmpty else {
            throw OpenAICompatibleError.missingAPIKey(
                "set \(Self.envVarName) env var. " +
                "DreamX Settings → AI saves the key to macOS Keychain and " +
                "DreamX Rust (PR 27) injects the value as \(Self.envVarName) " +
                "into the dream CLI subprocess at invocation time."
            )
        }

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeoutSeconds

        // OpenAI-compat chat completions request body. `stream: false` is
        // explicit — most providers default to false but we pin it so the
        // response shape is deterministic (single completion, not SSE).
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
            (data, response) = try await session.data(for: req)
        } catch {
            throw OpenAICompatibleError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleError.badStatus(http.statusCode, body: body)
        }
        // Parse OpenAI-compat response: { choices: [{ message: { content: "..." } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleError.malformedResponse(raw)
        }
        return content
    }
}
