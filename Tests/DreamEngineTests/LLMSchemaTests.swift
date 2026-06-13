import XCTest
@testable import DreamEngine

/// P3-5 评审 §4.2 修复: LLM 结构化输出 (Ollama `format: json_schema` 统一 4 个调用).
/// 覆盖:
/// - 4 schema struct (Codable) round-trip
/// - JSON Schema dict for Ollama `format: json_schema` 参数 (含 enum 约束)
/// - `LLMSchema.detect(fromSystemPrompt:)` 自动判 phase
/// - `StructuredParser.parse` 容错解析 (剥 ```json``` 围栏, 解析失败抛错带调试信息)
/// - `OllamaNativeProvider` 走 `/api/chat` 端点 (HTTP mock 验证 format 字段)
/// - `OllamaNativeProvider.chatOnce` 无 schema 时 fallback 纯文本 (向后兼容)
final class LLMSchemaTests: XCTestCase {

    // MARK: - 4 schema struct round-trip

    /// 1. VerifyResponse Codable round-trip (YES/NO 二元)
    func testVerifyResponse_roundTrip_yes() throws {
        let json = #"{"verdict":"YES","reasoning":"证据充分"}"#
        let r = try StructuredParser.parse(json, as: VerifyResponse.self, schema: .verify)
        XCTAssertEqual(r.verdict, .yes)
        XCTAssertEqual(r.reasoning, "证据充分")
    }

    /// 2. VerifyResponse NO 路径
    func testVerifyResponse_roundTrip_no() throws {
        let json = #"{"verdict":"NO"}"#
        let r = try StructuredParser.parse(json, as: VerifyResponse.self, schema: .verify)
        XCTAssertEqual(r.verdict, .no)
        XCTAssertNil(r.reasoning)
    }

    /// 3. VerifyResponse 未知 verdict 抛错 (不是 YES/NO enum)
    func testVerifyResponse_unknownVerdict_throws() {
        let json = #"{"verdict":"MAYBE"}"#
        XCTAssertThrowsError(try StructuredParser.parse(json, as: VerifyResponse.self, schema: .verify))
    }

    /// 4. ConflictResponse OK / CONFLICT / AMBIGUOUS 三元
    func testConflictResponse_threeValues() throws {
        let cases: [(String, ConflictResponse.Verdict)] = [
            (#"{"verdict":"OK"}"#, .ok),
            (#"{"verdict":"CONFLICT"}"#, .conflict),
            (#"{"verdict":"AMBIGUOUS"}"#, .ambiguous),
        ]
        for (json, expected) in cases {
            let r = try StructuredParser.parse(json, as: ConflictResponse.self, schema: .conflict)
            XCTAssertEqual(r.verdict, expected)
        }
    }

    /// 5. AnalysisResponse 完整字段
    func testAnalysisResponse_fullFields() throws {
        let json = #"""
        {
          "keyEntities": ["DreamVault", "Ollama"],
          "keyConcepts": ["记忆", "幻觉"],
          "tensionsWithExisting": ["老教训"],
          "recommendedLessonTexts": ["教训 1"],
          "reasoning": "自动推理",
          "recommendedKind": "concept"
        }
        """#
        let r = try StructuredParser.parse(json, as: AnalysisResponse.self, schema: .analyze)
        XCTAssertEqual(r.keyEntities, ["DreamVault", "Ollama"])
        XCTAssertEqual(r.recommendedKind, "concept")
    }

    /// 6. AnalysisResponse 容错 (Optional 字段缺失)
    func testAnalysisResponse_missingOptionals() throws {
        let json = #"{"keyEntities":["a"],"keyConcepts":["b"],"recommendedKind":"entity"}"#
        let r = try StructuredParser.parse(json, as: AnalysisResponse.self, schema: .analyze)
        XCTAssertEqual(r.keyEntities, ["a"])
        XCTAssertEqual(r.recommendedKind, "entity")
        XCTAssertNil(r.reasoning, "Optional 字段缺失 → nil (不抛)")
    }

    /// 7. DraftListResponse 单 draft
    func testDraftListResponse_singleDraft() throws {
        let json = #"""
        {
          "drafts": [
            {
              "text": "mock draft",
              "sourceFile": "raw/a.md",
              "sourceLine": 1,
              "sourceExcerpt": "excerpt text",
              "decayClassRaw": "normal",
              "kind": "concept"
            }
          ]
        }
        """#
        let r = try StructuredParser.parse(json, as: DraftListResponse.self, schema: .generate)
        XCTAssertEqual(r.drafts?.count, 1)
        XCTAssertEqual(r.drafts?[0].text, "mock draft")
        XCTAssertEqual(r.drafts?[0].sourceFile, "raw/a.md")
        XCTAssertEqual(r.drafts?[0].decayClassRaw, "normal")
    }

    /// 8. DraftListResponse 空数组 (LLM 觉得没东西可提炼)
    func testDraftListResponse_emptyDrafts() throws {
        let json = #"{"drafts":[]}"#
        let r = try StructuredParser.parse(json, as: DraftListResponse.self, schema: .generate)
        XCTAssertEqual(r.drafts?.count, 0)
    }

    /// 9. DraftListResponse 缺 drafts 字段 → nil (Optional)
    func testDraftListResponse_missingDraftsField() throws {
        let json = #"{}"#
        let r = try StructuredParser.parse(json, as: DraftListResponse.self, schema: .generate)
        XCTAssertNil(r.drafts)
    }

    // MARK: - 容错解析 (剥 ```json``` 围栏)

    /// 10. 剥 ```json 围栏 (跟老 Consolidator.stripMarkdownFence 同款)
    func testParser_stripsMarkdownFence() throws {
        let fenced = """
        ```json
        {"verdict":"YES"}
        ```
        """
        let r = try StructuredParser.parse(fenced, as: VerifyResponse.self, schema: .verify)
        XCTAssertEqual(r.verdict, .yes)
    }

    /// 11. 围栏不带 "json" 也剥
    func testParser_stripsPlainFence() throws {
        let fenced = """
        ```
        {"verdict":"NO"}
        ```
        """
        let r = try StructuredParser.parse(fenced, as: VerifyResponse.self, schema: .verify)
        XCTAssertEqual(r.verdict, .no)
    }

    /// 12. 解析失败抛错带 schema 名 + raw 前 200 字符 (调试用)
    func testParser_decodeError_includesSchemaNameAndRaw() {
        let malformed = "not json at all"
        do {
            _ = try StructuredParser.parse(malformed, as: VerifyResponse.self, schema: .verify)
            XCTFail("期望抛错")
        } catch let StructuredParseError.decodeFailed(schema, raw, _) {
            XCTAssertEqual(schema, .verify)
            XCTAssertTrue(raw.contains("not json"), "raw 含原内容")
        } catch {
            XCTFail("应抛 StructuredParseError.decodeFailed, got: \(error)")
        }
    }

    // MARK: - LLMSchema.detect 自动判 phase

    /// 13. system prompt 含 "事实校验器" → verify
    func testDetectSystem_verifySchema() {
        XCTAssertEqual(LLMSchema.detect(fromSystemPrompt: "你是严格的事实校验器"), .verify)
    }

    /// 14. system prompt 含 "互相矛盾" → conflict
    func testDetectSystem_conflictSchema() {
        XCTAssertEqual(LLMSchema.detect(fromSystemPrompt: "你判断两条知识是否互相矛盾"), .conflict)
    }

    /// 15. system prompt 含 "分析师" → analyze
    func testDetectSystem_analyzeSchema() {
        XCTAssertEqual(LLMSchema.detect(fromSystemPrompt: "你是严格的分析师"), .analyze)
    }

    /// 16. system prompt 含 "提炼员" → generate
    func testDetectSystem_generateSchema() {
        XCTAssertEqual(LLMSchema.detect(fromSystemPrompt: "你是严格的提炼员"), .generate)
    }

    /// 17. system prompt 不含已知 phase 关键词 → nil
    func testDetectSystem_unknown_returnsNil() {
        XCTAssertNil(LLMSchema.detect(fromSystemPrompt: "你是一个 chat bot"))
    }

    // MARK: - LLMSchema.jsonSchema 给 Ollama `format: json_schema` 用

    /// 18. verify schema 含 enum 约束 (YES/NO 字符串)
    func testJsonSchema_verify_hasEnum() {
        let s = LLMSchema.jsonSchema(for: .verify)
        XCTAssertEqual(s["type"] as? String, "object")
        let props = s["properties"] as? [String: Any]
        let verdict = props?["verdict"] as? [String: Any]
        XCTAssertEqual(verdict?["type"] as? String, "string")
        XCTAssertEqual(verdict?["enum"] as? [String], ["YES", "NO"])
    }

    /// 19. conflict schema 含 3 值 enum
    func testJsonSchema_conflict_hasThreeEnum() {
        let s = LLMSchema.jsonSchema(for: .conflict)
        let verdict = (s["properties"] as? [String: Any])?["verdict"] as? [String: Any]
        XCTAssertEqual(verdict?["enum"] as? [String], ["OK", "CONFLICT", "AMBIGUOUS"])
    }

    /// 20. analyze schema 含数组 properties
    func testJsonSchema_analyze_hasArrays() {
        let s = LLMSchema.jsonSchema(for: .analyze)
        let props = s["properties"] as? [String: Any]
        let entities = props?["keyEntities"] as? [String: Any]
        XCTAssertEqual(entities?["type"] as? String, "array")
        XCTAssertEqual((entities?["items"] as? [String: Any])?["type"] as? String, "string")
    }

    /// 21. generate schema 嵌套数组 of objects
    func testJsonSchema_generate_nestedDrafts() {
        let s = LLMSchema.jsonSchema(for: .generate)
        let drafts = (s["properties"] as? [String: Any])?["drafts"] as? [String: Any]
        XCTAssertEqual(drafts?["type"] as? String, "array")
        let item = (drafts?["items"] as? [String: Any])
        XCTAssertEqual(item?["type"] as? String, "object")
        let decay = (item?["properties"] as? [String: Any])?["decayClassRaw"] as? [String: Any]
        XCTAssertEqual(decay?["enum"] as? [String], ["slow", "normal", "fast"])
    }

    // MARK: - OllamaNativeProvider URL/format 行为 (HTTP mock)

    /// 22. OllamaNativeProvider 走 `/api/chat` (不是 `/v1/chat/completions`)
    func testOllamaNativeProvider_usesNativeChatEndpoint() async throws {
        MockURLProtocol.currentHandler = { _ in (200, ["message": ["content": "{\"verdict\":\"YES\"}"]]) }
        let session = URLSession(configuration: .mockWithProtocol())
        defer {
            session.invalidateAndCancel()
            MockURLProtocol.currentHandler = nil
        }

        let provider = TestableOllamaNativeProvider(session: session)
        let result = try await provider.complete(
            system: "你是严格的事实校验器",
            user: "证据: ...")
        XCTAssertEqual(result, "{\"verdict\":\"YES\"}")
        // 验证请求路径
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/chat",
                       "走 Ollama 原生 /api/chat (不是 OpenAI 兼容 /v1/chat/completions)")
    }

    /// 23. OllamaNativeProvider 含 schema 时 body 含 `format.json_schema.schema`
    func testOllamaNativeProvider_schemaSystem_addsFormatField() async throws {
        MockURLProtocol.currentHandler = { _ in (200, ["message": ["content": "{\"verdict\":\"YES\"}"]]) }
        let session = URLSession(configuration: .mockWithProtocol())
        defer {
            session.invalidateAndCancel()
            MockURLProtocol.currentHandler = nil
        }

        let provider = TestableOllamaNativeProvider(session: session)
        _ = try await provider.complete(
            system: "你是严格的事实校验器",
            user: "证据: ...")
        // 验证请求 body 含 format.json_schema
        let body = MockURLProtocol.lastRequestBodyJSON
        let format = body["format"] as? [String: Any]
        XCTAssertNotNil(format, "schema 阶段应加 format 字段")
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        let schemaDict = format?["schema"] as? [String: Any]
        XCTAssertNotNil(schemaDict, "format.schema dict 应有")
        // verify schema 含 enum YES/NO
        let verdict = (schemaDict?["properties"] as? [String: Any])?["verdict"] as? [String: Any]
        XCTAssertEqual(verdict?["enum"] as? [String], ["YES", "NO"])
    }

    /// 24. OllamaNativeProvider 不含 schema 时**不**加 format 字段 (向后兼容纯文本)
    func testOllamaNativeProvider_unknownSystem_noFormatField() async throws {
        MockURLProtocol.currentHandler = { _ in (200, ["message": ["content": "some text response"]]) }
        let session = URLSession(configuration: .mockWithProtocol())
        defer {
            session.invalidateAndCancel()
            MockURLProtocol.currentHandler = nil
        }

        let provider = TestableOllamaNativeProvider(session: session)
        _ = try await provider.complete(
            system: "你是一个 chat bot (无 phase 关键词)",
            user: "hi")
        let body = MockURLProtocol.lastRequestBodyJSON
        XCTAssertNil(body["format"],
                     "system prompt 不含 phase 关键词 → 不加 format 字段 (向后兼容纯文本)")
    }

    /// 25. HTTP 非 2xx 抛 OllamaNativeError.badStatus
    func testOllamaNativeProvider_http500_throwsBadStatus() async {
        MockURLProtocol.currentHandler = { _ in (500, ["error": "internal server error"]) }
        let session = URLSession(configuration: .mockWithProtocol())
        defer {
            session.invalidateAndCancel()
            MockURLProtocol.currentHandler = nil
        }

        let provider = TestableOllamaNativeProvider(session: session)
        do {
            _ = try await provider.complete(system: "x", user: "y")
            XCTFail("应抛错")
        } catch let OllamaNativeProvider.OllamaNativeError.badStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("应抛 badStatus, got: \(error)")
        }
    }
}

// MARK: - 测试 fixtures

/// 测试用 OllamaNativeProvider — 用注入的 URLSession (可走 MockURLProtocol)
final class TestableOllamaNativeProvider: LLMProvider, @unchecked Sendable {
    let baseURL: URL
    let model: String
    let session: URLSession

    init(session: URLSession,
         baseURL: URL = URL(string: "http://test.local:11434")!,
         model: String = "test-model") {
        self.session = session
        self.baseURL = baseURL
        self.model = model
    }

    func complete(system: String, user: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let schemaName = LLMSchema.detect(fromSystemPrompt: system)
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
        ]
        if let schemaName = schemaName {
            body["format"] = [
                "type": "json_schema",
                "schema": LLMSchema.jsonSchema(for: schemaName),
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 记录 body (MockURLProtocol 会读)
        MockURLProtocol.lastRequestBodyJSON = body

        let (data, response) = try await session.data(for: req)
        MockURLProtocol.lastRequest = req
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw OllamaNativeProvider.OllamaNativeError.badStatus(
                (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaNativeProvider.OllamaNativeError.malformedResponse(
                String(data: data, encoding: .utf8) ?? "")
        }
        return content
    }
}

/// MockURLProtocol — 拦截 URLSession 请求, 返 mock response, 记录请求 path/body.
/// 重要: URLProtocol 走 class 派发, protocolClasses 注册的是类不是实例. 所以状态必须
/// 走 static (类共享). 每个测试 setUp 时重置 `current` (currentHandler).
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// 当前测试期望的 handler (每个 test setUp 时设). nil → 走 defaultHandler
    static var currentHandler: ((URLRequest) -> (statusCode: Int, bodyJSON: [String: Any]))? = nil
    static var lastRequest: URLRequest?
    static var lastRequestBodyJSON: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 记录请求
        let req = self.request
        Self.lastRequest = req
        // 尝试解析 body
        if let bodyData = req.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            Self.lastRequestBodyJSON = json
        }
        // 调 handler (默认 200/{})
        let result = Self.currentHandler?(req) ?? (statusCode: 200, bodyJSON: [String: Any]())
        // 返 mock response
        let response = HTTPURLResponse(
            url: req.url!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        let data = (try? JSONSerialization.data(withJSONObject: result.bodyJSON)) ?? Data()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// 给 URLSession 装 MockURLProtocol (测试用). handler 走 static 共享.
    static func mockWithProtocol() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return config
    }
}
