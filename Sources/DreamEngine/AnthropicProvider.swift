import Foundation

// MARK: - AnthropicProvider（v0.6 PR 36: Anthropic Messages API provider）
//
// Anthropic 用自有的 Messages API，**不是** OpenAI-compat:
//   - endpoint: POST {baseURL}/v1/messages
//   - auth: `x-api-key: {apiKey}` header (NOT `Authorization: Bearer`)
//   - required header: `anthropic-version: 2023-06-01`
//   - system 是顶层 string, 不是 messages 数组的第一个元素
//   - max_tokens 是必填 (Anthropic 强制)
//   - response: { content: [{ type: "text", text: "..." }, ...] }
//
// 设计取舍:
// - **不读 macOS Keychain**. 与 OpenAICompatibleProvider 同 boundary 锁 (PR 28 / PR 34):
//   DreamX Rust (PR 27) 从 Keychain 读 value, 通过 Command::env() 注入
//   `DREAMFORGE_LLM_API_KEY` env var. 本 type 在 init 时一次性读 env var.
// - **6 类错误 contract** (与 PR 34 OpenAI 6 类同 shape, 不同 tag 前缀):
//   `[ANTHROPIC_MISSING_KEY]` / `[ANTHROPIC_AUTH_FAILED]` /
//   `[ANTHROPIC_MODEL_NOT_FOUND]` / `[ANTHROPIC_TIMEOUT]` /
//   `[ANTHROPIC_MALFORMED]` / `[ANTHROPIC_NETWORK_FAILED]`.
//   DreamX DreamPanel parser 识别这些 prefix 并映射到 short actionable copy.
// - **不做 streaming**. 与 OpenAICompatibleProvider 同.
// - **不做 retry / exponential backoff**. 简单 fail-fast, caller 决定是否 retry.
//
// URL convention: dreamforge Rust (PR 10) strips trailing `/v1` before passing
// to dream CLI. AnthropicProvider 期望 baseURL 是没有 `/v1` 后缀的根 (e.g.
// `https://api.anthropic.com`), 它 append `/v1/messages`. 测试用
// `https://test.invalid` root 让 path 断言 unambiguous (`/v1/messages`).
public struct AnthropicProvider: LLMProvider, Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let timeoutSeconds: TimeInterval
    /// Anthropic Messages API version header. Pinned per Anthropic docs.
    public static let apiVersion = "2023-06-01"
    /// Default max_tokens for the request. Anthropic requires this field.
    /// 1024 is enough for the Consolidator / ContradictionDetector short replies.
    public static let defaultMaxTokens = 1024
    /// URLSession for HTTP. Defaults to `.shared` in production; tests inject
    /// a mock-backed session via `URLSession(configuration: .mockWithProtocol())`.
    public let session: URLSession

    /// env var name DreamX 注入 (PR 24 + PR 27). 与 OpenAICompatibleProvider
    /// 共享同一个 env var (`DREAMFORGE_LLM_API_KEY`): DreamX Rust 不知道也不该
    /// 关心 active provider 用什么协议, 它只负责把 key 注入 env, 真正的协议
    /// 选择由 `dream --llm <provider>` flag 决定.
    public static let envVarName = "DREAMFORGE_LLM_API_KEY"

    public init(baseURL: URL,
                model: String,
                apiKey: String? = nil,
                timeoutSeconds: TimeInterval = 120,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        // API key resolution (init-time only) — same shape as
        // OpenAICompatibleProvider so DreamX Rust doesn't need to know
        // about per-provider env var names.
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

    public enum AnthropicError: Error, CustomStringConvertible, LocalizedError {
        /// v0.6 PR 36 contract: 6 stable categories matching PR 34's
        /// 6-category contract for OpenAI-compat, with `[ANTHROPIC_*]`
        /// tag prefix instead of `[OPENAI_*]`. DreamX DreamPanel parser
        /// recognizes both prefixes and maps to the same UI copy.
        case missingAPIKey(String)
        case authFailed(Int, body: String)
        case modelNotFound(Int, body: String)
        case timeout
        case malformedResponse(String)
        case networkFailed(String)

        public var description: String {
            switch self {
            case .missingAPIKey(let hint):
                return "[ANTHROPIC_MISSING_KEY] Anthropic missing API key: \(hint)"
            case .authFailed(let code, let body):
                return "[ANTHROPIC_AUTH_FAILED] Anthropic HTTP \(code): \(body)"
            case .modelNotFound(let code, let body):
                return "[ANTHROPIC_MODEL_NOT_FOUND] Anthropic HTTP \(code): \(body)"
            case .timeout:
                return "[ANTHROPIC_TIMEOUT] Anthropic request timed out after the configured timeout"
            case .malformedResponse(let s):
                return "[ANTHROPIC_MALFORMED] Anthropic response malformed: \(s)"
            case .networkFailed(let detail):
                return "[ANTHROPIC_NETWORK_FAILED] Anthropic network failed: \(detail)"
            }
        }

        public var errorDescription: String? { description }

        /// Stable category label. Values match PR 34's 6 categories
        /// (no provider name in the value) so DreamX UI can map all
        /// three providers (OpenAI/Anthropic/Gemini) to the same
        /// short actionable copy.
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
        // Missing key check BEFORE making any HTTP request. Same UX
        // invariant as OpenAICompatibleProvider: don't burn a network
        // round-trip on a misconfigured setup.
        guard let apiKey, !apiKey.isEmpty else {
            throw AnthropicError.missingAPIKey(
                "set \(Self.envVarName) env var. " +
                "DreamX Settings → AI saves the key to macOS Keychain and " +
                "DreamX Rust (PR 27) injects the value as \(Self.envVarName) " +
                "into the dream CLI subprocess at invocation time."
            )
        }

        let url = baseURL.appendingPathComponent("v1/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic uses `x-api-key` header (NOT Bearer).
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = timeoutSeconds

        // Anthropic Messages API body shape:
        //   - `system` is a top-level string (NOT a messages array entry)
        //   - `messages` only contains the user turn (no system role)
        //   - `max_tokens` is required
        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.defaultMaxTokens,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            throw AnthropicError.timeout
        } catch {
            throw AnthropicError.networkFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Same 6-category split as OpenAICompatibleProvider.
            switch http.statusCode {
            case 401, 403:
                throw AnthropicError.authFailed(http.statusCode, body: body)
            case 404:
                throw AnthropicError.modelNotFound(http.statusCode, body: body)
            default:
                throw AnthropicError.networkFailed(
                    "HTTP \(http.statusCode): \(body)"
                )
            }
        }
        // Parse Anthropic response: { content: [{ type: "text", text: "..." }] }
        // We take the FIRST text content block. If `type` is "tool_use" or
        // something else (Anthropic supports tool calls in responses), we
        // skip and look for the next text block. If no text block exists,
        // malformed.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.malformedResponse(raw)
        }
        for block in contentBlocks {
            if block["type"] as? String == "text",
               let text = block["text"] as? String {
                return text
            }
        }
        // No text block in the response — likely a tool_use-only response
        // or a non-standard completion. Surface as malformed so the caller
        // can decide whether to retry or report.
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw AnthropicError.malformedResponse(raw)
    }
}
