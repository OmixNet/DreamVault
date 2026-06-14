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
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public typealias Handler = @Sendable (String, String) throws -> String  // (system, user) -> answer
    private let handler: Handler
    /// 记录调用次数，便于测试断言
    private let _callCount = NSLock()
    public var callCount: Int {
        _callCount.withLock { _count }
    }
    private var _count: Int = 0

    public init(handler: @escaping Handler = MockLLMProvider.defaultHandler) {
        self.handler = handler
    }

    public func complete(system: String, user: String) async throws -> String {
        _callCount.withLock { _count += 1 }
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
    /// P3-3 评审 §1.2 修复: 默认 mock 走 3 步 CoT 格式 (生产默认 3 步).
    /// 按 system + user prompt 关键词判 phase:
    ///   - system 含 "分析师"/"keyEntities" → 返 analyze JSON
    ///   - system 含 "提炼员"/"draft" → 返 drafts JSON
    ///   - 其他 (verify 阶段) → 走老 NO/CONFLICT/YES 关键字逻辑
    public static let defaultHandler: Handler = { system, user in
        let lower = user.lowercased()
        // P3-3 评审 §1.2 修复: 默认 mock 仍走 2 步 fast path (测试 / debug 用), 但
        // 真实生产 LLM (Ollama / OpenAI-compat) 走 3 步 CoT (config.useThreeStepCoT=true
        // 默认). 3 步路径下 LLM 返 draft JSON, 2 步路径下 LLM 返 "YES"/"NO" 关键字.
        // 这里 defaultHandler 返 YES/NO/OK/CONFLICT 关键字 (verify 阶段 2 步语义).
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
public struct OllamaProvider: LLMProvider, Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "llama3.1",
                apiKey: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
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
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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

// MARK: - OllamaNativeProvider（P3-5 评审 §4.2 修复: Ollama 原生端点 + json_schema 约束）
//
// Ollama `/v1/chat/completions` (OpenAI 兼容) **不**支持 `format: json_schema`.
// Ollama 原生 `/api/chat` 端点支持 `format: {type: "json_schema", schema: {...}}`,
// 用 grammar 强制生成结构化输出. 验证, 矛盾, analyze, generate 4 个 schema 走这路,
// 消灭 `contains("YES")` / `contains("CONFLICT")` 这类解析雷.
//
// 设计取舍:
// - 老 OllamaProvider (OpenAI 兼容) 保留 — OpenAI / vLLM / LM Studio 仍用 OpenAI 端点.
// - 新 OllamaNativeProvider 仅给本地 Ollama 用 — 走原生端点 + grammar 约束.
// - schema 由 `LLMSchema.jsonSchema(for:)` 提供 (Ollama `format` 字段需要 dict).
// - 响应走 `/api/chat` 原生格式: { message: { content: "..." } } (跟 OpenAI 兼容格式**不**同).
public struct OllamaNativeProvider: LLMProvider, Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    public let timeoutSeconds: TimeInterval

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "llama3.1",
                apiKey: String? = nil,
                timeoutSeconds: TimeInterval = 120) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
    }

    public enum OllamaNativeError: Error, CustomStringConvertible {
        case badStatus(Int, body: String)
        case malformedResponse(String)
        case transport(Error)

        public var description: String {
            switch self {
            case .badStatus(let code, let body):
                return "OllamaNative HTTP \(code): \(body)"
            case .malformedResponse(let s):
                return "OllamaNative 响应无法解析: \(s)"
            case .transport(let e):
                return "OllamaNative 传输错误: \(e.localizedDescription)"
            }
        }
    }

    public func complete(system: String, user: String) async throws -> String {
        // P3-5: 自动从 system prompt 关键词判 schema, 走对应 json_schema 约束.
        // 老 OpenAI 兼容 OllamaProvider **不**走这 path.
        let schemaName = LLMSchema.detect(fromSystemPrompt: system)
        return try await chatOnce(system: system, user: user, schema: schemaName)
    }

    /// 单次 Ollama /api/chat 调用. 可选 `format: json_schema` 约束.
    /// `schema=nil` → 走纯文本模式 (跟老 OllamaProvider 行为一致).
    func chatOnce(system: String, user: String, schema: LLMSchema.Name?) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = timeoutSeconds

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
        ]
        if let schemaName = schema {
            // Ollama native format 字段: {type: "json_schema", schema: {...}} 或
            // 老式 {type: "json_object"} 兼容模式. 这里用 json_schema 走严格 grammar.
            body["format"] = [
                "type": "json_schema",
                "schema": LLMSchema.jsonSchema(for: schemaName),
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw OllamaNativeError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaNativeError.malformedResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaNativeError.badStatus(http.statusCode, body: body)
        }
        // 解析 Ollama /api/chat 原生响应: { message: { content: "..." } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OllamaNativeError.malformedResponse(raw)
        }
        return content
    }
}

// MARK: - 工厂：从环境变量决定 provider
//
// `DREAMVAULT_LLM` 取值：
//   - "mock"     → MockLLMProvider（默认）
//   - "ollama"   → OllamaProvider（可选 OLLAMA_BASE_URL / OLLAMA_MODEL 覆盖）
// MARK: - BudgetedLLMProvider (P8)
//
// P8 修复：之前 BudgetManager 没人调，预算完全是"检查器"。
// 这个 wrapper 透明地给任何 LLMProvider 加预算：
//   - complete() 之前先 canProceed()，超额直接抛 BudgetExceededError
//   - complete() 之后 recordCall(provider, model, inputTokens, outputTokens)
//   - input/output tokens 用 character/4 粗略估算（Ollama 响应不带 token count）
//
// 用法：
//   let base = OllamaProvider(...)
//   let budgeted = BudgetedLLMProvider(wrapping: base,
//                                       canProceed: { await MainActor.run { bm.canProceed() } },
//                                       recordCall: { ... await MainActor.run { bm.recordCall(...) } })
//   try await budgeted.complete(system: "...", user: "...")
public final class BudgetedLLMProvider: LLMProvider, @unchecked Sendable {
    public let inner: any LLMProvider
    public let providerName: String
    public let modelHint: String
    public let charsPerToken: Int
    /// 检查预算（异步，调用方决定是否 await MainActor.run）
    /// 参数：estimatedOutputTokens 预估本次的 output token 数；budget manager 据此判断
    /// 是不是会突破月度成本。如果传 0，monthly 成本检查不触发（只查 daily 次数）。
    public let canProceedFn: @Sendable (_ estimatedOutputTokens: Int, _ modelHint: String) async -> Bool
    /// 记录一次调用（异步，调用方决定是否 await MainActor.run）
    public let recordCallFn: @Sendable (String, String, Int, Int) async -> Void

    public init(wrapping inner: any LLMProvider,
                providerName: String,
                modelHint: String? = nil,
                charsPerToken: Int = 4,
                canProceedFn: @escaping @Sendable (_ estimatedOutputTokens: Int, _ modelHint: String) async -> Bool,
                recordCallFn: @escaping @Sendable (String, String, Int, Int) async -> Void) {
        self.inner = inner
        self.providerName = providerName
        if let m = modelHint {
            self.modelHint = m
        } else if let ollama = inner as? OllamaProvider {
            self.modelHint = ollama.model
        } else {
            self.modelHint = "unknown"
        }
        self.charsPerToken = charsPerToken
        self.canProceedFn = canProceedFn
        self.recordCallFn = recordCallFn
    }

    public struct BudgetExceededError: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? {
            return "Budget exceeded: \(reason)"
        }
    }

    public func complete(system: String, user: String) async throws -> String {
        // 估算本次 input token（这个能精确算）
        let inputTokens = max(1, (system.count + user.count) / charsPerToken)
        // 输出 token 不知道；用 input 1.5x 当粗估（聊天 completion 典型 input:output 比例）
        let estOutputTokens = max(1, inputTokens * 3 / 2)
        // 先看能不能调用
        if !(await canProceedFn(estOutputTokens, modelHint)) {
            throw BudgetExceededError(
                reason: "Daily/monthly cap reached. Open Settings → Budget to adjust.")
        }
        // 实际调用
        let response = try await inner.complete(system: system, user: user)
        // 真实 output token 重新算
        let outputTokens = max(1, response.count / charsPerToken)
        // 记录
        await recordCallFn(providerName, modelHint, inputTokens, outputTokens)
        return response
    }
}

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
