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
        /// v0.6 PR 34 contract: 6 stable categories that DreamX UI maps to
        /// short actionable copy. Each case's description is prefixed with
        /// `[OPENAI_<CATEGORY>]` so DreamX can pattern-match without parsing
        /// free-form error text. The 6 categories:
        ///
        /// 1. `.missingAPIKey` — env var unset, no HTTP request issued
        /// 2. `.authFailed` — HTTP 401 / 403 (key wrong or revoked)
        /// 3. `.modelNotFound` — HTTP 404 (model id doesn't exist on provider)
        /// 4. `.timeout` — `URLError.timedOut` (request exceeded timeoutSeconds)
        /// 5. `.malformedResponse` — 2xx but response shape doesn't match
        ///    OpenAI-compat `{ choices: [{ message: { content: "..." } }] }`
        /// 6. `.networkFailed` — catch-all: 5xx, other 4xx (rate limit etc.),
        ///    DNS / TCP / TLS / unknown URLError. Surfaced as "network failed"
        ///    because from a user perspective "server rejected / unreachable"
        ///    and "DNS failed" are the same fix action (retry / check network).
        case missingAPIKey(String)
        case authFailed(Int, body: String)
        case modelNotFound(Int, body: String)
        case timeout
        case malformedResponse(String)
        case networkFailed(String)

        public var description: String {
            switch self {
            case .missingAPIKey(let hint):
                return "[OPENAI_MISSING_KEY] OpenAI-compatible missing API key: \(hint)"
            case .authFailed(let code, let body):
                return "[OPENAI_AUTH_FAILED] OpenAI-compatible HTTP \(code): \(body)"
            case .modelNotFound(let code, let body):
                return "[OPENAI_MODEL_NOT_FOUND] OpenAI-compatible HTTP \(code): \(body)"
            case .timeout:
                return "[OPENAI_TIMEOUT] OpenAI-compatible request timed out after the configured timeout"
            case .malformedResponse(let s):
                return "[OPENAI_MALFORMED] OpenAI-compatible response malformed: \(s)"
            case .networkFailed(let detail):
                return "[OPENAI_NETWORK_FAILED] OpenAI-compatible network failed: \(detail)"
            }
        }

        public var errorDescription: String? { description }

        /// Stable category label used by error-format tests + DreamX UI.
        /// The 6 values correspond 1:1 to the user's v0.6 plan categories
        /// (PR 34). NOT for stable error.message matching — DreamX consumes
        /// the `[OPENAI_<CATEGORY>]` prefix in `description` for parsing.
        public var category: String {
            switch self {
            case .missingAPIKey: return "missing-api-key"
            case .authFailed: return "auth-failed"
            case .modelNotFound: return "model-not-found"
            case .timeout: return "timeout"
            case .malformedResponse: return "malformed-response"
            case .networkFailed: return "network-failed"
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
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAICompatibleError.timeout
        } catch {
            throw OpenAICompatibleError.networkFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // 6-category split (v0.6 PR 34): auth vs model-not-found vs catch-all
            switch http.statusCode {
            case 401, 403:
                throw OpenAICompatibleError.authFailed(http.statusCode, body: body)
            case 404:
                throw OpenAICompatibleError.modelNotFound(http.statusCode, body: body)
            default:
                // 5xx, 400, 405, 429, etc. all surface as "network failed" —
                // from a user perspective, "server rejected" and "server
                // unreachable" share the same fix action (retry / check).
                throw OpenAICompatibleError.networkFailed(
                    "HTTP \(http.statusCode): \(body)"
                )
            }
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
