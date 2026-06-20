import Foundation

// MARK: - GeminiProvider（v0.6 PR 36: Google Gemini generateContent provider）
//
// Gemini 用自有的 generateContent API, **不是** OpenAI-compat, **不是** Anthropic:
//   - endpoint: POST {baseURL}/v1beta/models/{model}:generateContent
//   - auth: `x-goog-api-key: {apiKey}` header (新; query param `?key=` 旧且被 deprecate)
//   - system 是顶层 `systemInstruction: { parts: [{text: "..."}] }` 字段
//   - contents 是 `{ role: "user", parts: [{text: "..."}] }` 数组
//   - response: { candidates: [{ content: { parts: [{text: "..."}] } }] }
//
// 设计取舍:
// - **不读 macOS Keychain**. 与 OpenAICompatibleProvider / AnthropicProvider
//   同 boundary 锁 (PR 28 / PR 34 / PR 36).
// - **6 类错误 contract** (与 PR 34 OpenAI 6 类同 shape, 不同 tag 前缀):
//   `[GEMINI_MISSING_KEY]` / `[GEMINI_AUTH_FAILED]` /
//   `[GEMINI_MODEL_NOT_FOUND]` / `[GEMINI_TIMEOUT]` /
//   `[GEMINI_MALFORMED]` / `[GEMINI_NETWORK_FAILED]`.
//   DreamX DreamPanel parser 识别这些 prefix 并映射到 short actionable copy.
// - **不做 streaming**. 与其他 provider 同.
// - **URL 拼接**: `:generateContent` 是 path suffix (冒号) 不是 directory, 不能
//   用 URLComponents.path 直接 append. 改用 URLComponents + percent encoding
//   保留冒号 (Gemini API 要求 `:generateContent` literal 在 path 里).
public struct GeminiProvider: LLMProvider, Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let timeoutSeconds: TimeInterval
    /// URLSession for HTTP. Defaults to `.shared` in production; tests inject
    /// a mock-backed session via `URLSession(configuration: .mockWithProtocol())`.
    public let session: URLSession

    /// env var name DreamX 注入 (PR 24 + PR 27). 与 OpenAICompatibleProvider /
    /// AnthropicProvider 共享同一个 env var: DreamX Rust 不知道也不该关心
    /// active provider 用什么协议.
    public static let envVarName = "DREAMFORGE_LLM_API_KEY"

    public init(baseURL: URL,
                model: String,
                apiKey: String? = nil,
                timeoutSeconds: TimeInterval = 120,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
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

    public enum GeminiError: Error, CustomStringConvertible, LocalizedError {
        /// v0.6 PR 36 contract: 6 stable categories matching PR 34's
        /// 6-category contract, with `[GEMINI_*]` tag prefix.
        case missingAPIKey(String)
        case authFailed(Int, body: String)
        case modelNotFound(Int, body: String)
        case timeout
        case malformedResponse(String)
        case networkFailed(String)

        public var description: String {
            switch self {
            case .missingAPIKey(let hint):
                return "[GEMINI_MISSING_KEY] Gemini missing API key: \(hint)"
            case .authFailed(let code, let body):
                return "[GEMINI_AUTH_FAILED] Gemini HTTP \(code): \(body)"
            case .modelNotFound(let code, let body):
                return "[GEMINI_MODEL_NOT_FOUND] Gemini HTTP \(code): \(body)"
            case .timeout:
                return "[GEMINI_TIMEOUT] Gemini request timed out after the configured timeout"
            case .malformedResponse(let s):
                return "[GEMINI_MALFORMED] Gemini response malformed: \(s)"
            case .networkFailed(let detail):
                return "[GEMINI_NETWORK_FAILED] Gemini network failed: \(detail)"
            }
        }

        public var errorDescription: String? { description }

        /// Stable category label. Same values as PR 34 — provider name
        /// is in the prefix tag, NOT in the category value.
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
        // Missing key check BEFORE making any HTTP request.
        guard let apiKey, !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey(
                "set \(Self.envVarName) env var. " +
                "DreamX Settings → AI saves the key to macOS Keychain and " +
                "DreamX Rust (PR 27) injects the value as \(Self.envVarName) " +
                "into the dream CLI subprocess at invocation time."
            )
        }

        // Gemini URL shape: {baseURL}/v1beta/models/{model}:generateContent
        // The `:generateContent` is a literal suffix on the model segment,
        // not a separate path. URLComponents + manual string concatenation
        // is the cleanest way to keep the colon literal (URLComponents
        // would percent-encode it).
        let urlString = "\(baseURL.absoluteString)/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GeminiError.malformedResponse("invalid URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Gemini x-goog-api-key header (newer; query param `?key=` is deprecated).
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = timeoutSeconds

        // Gemini request body:
        //   - systemInstruction is a top-level object, NOT a contents entry
        //   - contents is `[{ role: "user", parts: [{text: "..."}] }]`
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": system]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": user]],
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiError.timeout
        } catch {
            throw GeminiError.networkFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw GeminiError.authFailed(http.statusCode, body: body)
            case 404:
                // Gemini returns 404 for both "model not found" and
                // "endpoint not found" — both surface as modelNotFound
                // (user fixes by editing the model id or base URL).
                throw GeminiError.modelNotFound(http.statusCode, body: body)
            default:
                throw GeminiError.networkFailed(
                    "HTTP \(http.statusCode): \(body)"
                )
            }
        }
        // Parse Gemini response:
        //   { candidates: [{ content: { parts: [{text: "..."}] } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.malformedResponse(raw)
        }
        // Take the FIRST text part. Gemini can return multiple parts
        // (e.g. text + functionCall), but for chat completion we just
        // want the text.
        for part in parts {
            if let text = part["text"] as? String {
                return text
            }
        }
        // No text part in the response (likely functionCall-only).
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw GeminiError.malformedResponse(raw)
    }
}
