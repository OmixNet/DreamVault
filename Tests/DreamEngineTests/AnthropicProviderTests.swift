import XCTest
@testable import DreamEngine

/// v0.6 PR 36: AnthropicProvider unit tests.
///
/// Coverage mirrors PR 28 / PR 34 OpenAICompatibleProviderTests:
///   1. request shape: POST /v1/messages + Content-Type + x-api-key + anthropic-version
///   2. 200 + typical Anthropic response → `content[0].text` (text block)
///   3. HTTP 401 → `.authFailed(401, body: ...)` (with `[ANTHROPIC_AUTH_FAILED]` tag)
///   4. HTTP 404 → `.modelNotFound(404, body: ...)` (with `[ANTHROPIC_MODEL_NOT_FOUND]` tag)
///   5. HTTP 500 → `.networkFailed("HTTP 500: ...")` (5xx merged with other URLError)
///   6. URLError.timedOut → `.timeout` (split from .networkFailed)
///   7. URLError.notConnectedToInternet → `.networkFailed(...)` (split from .timeout)
///   8. malformed response (missing text block) → `.malformedResponse`
///   9. missing API key (env var empty, no init apiKey) → `.missingAPIKey`,
///      NO HTTP request issued
///  10. security invariant: apiKey VALUE never appears in error description
///  11. error category stability (6 cases, same shape as PR 34)
///  12. v0.6 PR 36 contract: every error description is prefixed with
///      a stable `[ANTHROPIC_*]` tag
///
/// Boundary lock (user 2026-06-19 拍板, preserved through PR 36):
///   - `GlobalOptions.makeProvider` returns provider that throws
///     `.missingAPIKey` when env var is empty (NOT fallback to Ollama /
///     NOT fallback to Keychain / NOT fallback to OpenAICompatibleProvider).
final class AnthropicProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeMockSession() -> (URLSession, () -> Void) {
        let session = URLSession(configuration: .mockWithProtocol())
        return (session, {
            session.invalidateAndCancel()
            MockURLProtocol.currentHandler = nil
            MockURLProtocol.lastRequest = nil
            MockURLProtocol.lastRequestBodyJSON = [:]
        })
    }

    /// Standard Anthropic Messages success response: { content: [{ type: "text", text: "..." }] }
    private func anthropicSuccessResponse(text: String) -> [String: Any] {
        return [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "text", "text": text],
            ],
            "model": "claude-sonnet-4-5",
            "stop_reason": "end_turn",
        ]
    }

    // MARK: - Tests

    /// 1 + 2: request shape + happy path. Verifies the provider sends
    /// the Anthropic-specific HTTP request shape (POST /v1/messages +
    /// x-api-key + anthropic-version) and extracts the text from a
    /// typical Anthropic Messages response.
    func testComplete_happyPath_sendsCorrectRequestAndParsesText() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (200, self.anthropicSuccessResponse(text: "YES"))
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "sk-ant-test-key",
            session: session
        )
        let result = try await provider.complete(system: "sys", user: "usr")
        XCTAssertEqual(result, "YES")

        // Request shape: POST /v1/messages + Content-Type + x-api-key + anthropic-version
        let req = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        // No Bearer auth (Anthropic uses x-api-key, NOT Authorization).
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "Anthropic must NOT use Authorization: Bearer header")

        // Body shape: { model, max_tokens, system, messages: [{role, content}] }
        let body = MockURLProtocol.lastRequestBodyJSON
        XCTAssertFalse(body.isEmpty, "body must be captured (via stream)")
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicProvider.defaultMaxTokens)
        XCTAssertEqual(body["system"] as? String, "sys")
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1, "Anthropic system is top-level, NOT a messages entry")
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        XCTAssertEqual(messages?[0]["content"] as? String, "usr")
    }

    /// 3: HTTP 401 → `.authFailed(401, body: ...)` with stable tag.
    func testComplete_http401_throwsAuthFailed() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (401, ["error": ["message": "invalid x-api-key"]])
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "sk-ant-bad-key",
            session: session
        )

        do {
            _ = try await provider.complete(system: "sys", user: "usr")
            XCTFail("expected throw on 401")
        } catch let AnthropicProvider.AnthropicError.authFailed(code, body) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("invalid x-api-key"))
            XCTAssertFalse(body.contains("sk-ant-bad-key"),
                            "apiKey value must not leak into error body: \(body)")
            // PR 36: description is prefixed with [ANTHROPIC_AUTH_FAILED].
            let desc = AnthropicProvider.AnthropicError
                .authFailed(code, body: body).description
            XCTAssertTrue(desc.hasPrefix("[ANTHROPIC_AUTH_FAILED]"),
                          "description must start with [ANTHROPIC_AUTH_FAILED] tag: \(desc)")
        } catch {
            XCTFail("expected .authFailed, got \(error)")
        }
    }

    /// 4: HTTP 404 → `.modelNotFound(404, body: ...)` with stable tag.
    func testComplete_http404_throwsModelNotFound() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (404, ["error": ["message": "model: claude-bogus not found"]])
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-bogus",
            apiKey: "sk-ant-test",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on 404")
        } catch let AnthropicProvider.AnthropicError.modelNotFound(code, _) {
            XCTAssertEqual(code, 404)
            let desc = AnthropicProvider.AnthropicError
                .modelNotFound(code, body: "x").description
            XCTAssertTrue(desc.hasPrefix("[ANTHROPIC_MODEL_NOT_FOUND]"),
                          "description must start with [ANTHROPIC_MODEL_NOT_FOUND] tag: \(desc)")
        } catch {
            XCTFail("expected .modelNotFound, got \(error)")
        }
    }

    /// 5: 200 but malformed response (no text block) → `.malformedResponse`.
    func testComplete_malformedResponse_throwsMalformed() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        // 200 with only a tool_use block (no text)
        MockURLProtocol.currentHandler = { _ in
            (200, [
                "content": [
                    ["type": "tool_use", "id": "x", "name": "y", "input": [:]],
                ],
            ])
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "sk-ant-test",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on tool_use-only response")
        } catch AnthropicProvider.AnthropicError.malformedResponse {
            // Expected
        } catch {
            XCTFail("expected .malformedResponse, got \(error)")
        }
    }

    /// 6: URLError.timedOut → `.timeout`.
    func testComplete_transportTimedOut_throwsTimeout() async throws {
        let (_, cleanup) = makeMockSession()
        defer { cleanup() }

        final class TimeoutErrorSimulator: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            override func stopLoading() {}
        }
        let timeoutSession = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [TimeoutErrorSimulator.self]
            return cfg
        }())
        defer { timeoutSession.invalidateAndCancel() }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "sk-ant-test",
            session: timeoutSession
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on timeout")
        } catch AnthropicProvider.AnthropicError.timeout {
            // Expected. PR 36: description is prefixed with [ANTHROPIC_TIMEOUT].
            let desc = AnthropicProvider.AnthropicError.timeout.description
            XCTAssertTrue(desc.hasPrefix("[ANTHROPIC_TIMEOUT]"),
                          "description must start with [ANTHROPIC_TIMEOUT] tag: \(desc)")
        } catch {
            XCTFail("expected .timeout, got \(error)")
        }
    }

    /// 7: non-timeout transport error → `.networkFailed`.
    func testComplete_transportNotConnected_throwsNetworkFailed() async throws {
        let (_, cleanup) = makeMockSession()
        defer { cleanup() }

        final class TransportErrorSimulator: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
            override func stopLoading() {}
        }
        let transportSession = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [TransportErrorSimulator.self]
            return cfg
        }())
        defer { transportSession.invalidateAndCancel() }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "sk-ant-test",
            session: transportSession
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on transport error")
        } catch AnthropicProvider.AnthropicError.networkFailed {
            // Expected
        } catch {
            XCTFail("expected .networkFailed, got \(error)")
        }
    }

    /// 8: missing API key → `.missingAPIKey` immediately, NO HTTP request.
    func testComplete_missingAPIKey_throwsImmediatelyNoHTTPRequest() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            XCTFail("HTTP request should NOT be made when apiKey is missing")
            return (200, [:])
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "",  // explicit empty
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on missing apiKey")
        } catch let AnthropicProvider.AnthropicError.missingAPIKey(hint) {
            XCTAssertTrue(hint.contains("DREAMFORGE_LLM_API_KEY"),
                          "hint should mention the env var: \(hint)")
            // PR 36: description prefix.
            let desc = AnthropicProvider.AnthropicError
                .missingAPIKey(hint).description
            XCTAssertTrue(desc.hasPrefix("[ANTHROPIC_MISSING_KEY]"),
                          "description must start with [ANTHROPIC_MISSING_KEY] tag: \(desc)")
        } catch {
            XCTFail("expected .missingAPIKey, got \(error)")
        }

        // CRITICAL: no HTTP request must have been issued.
        XCTAssertNil(MockURLProtocol.lastRequest,
                     "HTTP request must NOT be made when apiKey is missing")
    }

    /// 9: security invariant — apiKey VALUE never appears in error description.
    func testComplete_doesNotLeakAPIKeyIntoErrorDescription() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (500, ["error": "internal error, please contact SECRET-LEAK-12345"])
        }

        let provider = AnthropicProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "claude-sonnet-4-5",
            apiKey: "SECRET-LEAK-12345",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on 500")
        } catch let AnthropicProvider.AnthropicError.networkFailed(detail) {
            XCTAssertTrue(detail.contains("HTTP 500"))
            // apiKey must appear exactly once in detail (the server's echo).
            XCTAssertEqual(detail.components(separatedBy: "SECRET-LEAK-12345").count - 1, 1)

            let desc = AnthropicProvider.AnthropicError
                .networkFailed(detail).description
            XCTAssertTrue(desc.hasPrefix("[ANTHROPIC_NETWORK_FAILED]"),
                          "description must start with [ANTHROPIC_NETWORK_FAILED] tag: \(desc)")
        } catch {
            XCTFail("expected .networkFailed, got \(error)")
        }
    }

    /// 10: error category stability — same 6 values as PR 34.
    func testErrorCategory_isStableAcrossCases() {
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.missingAPIKey("hint").category,
            "missing-api-key"
        )
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.authFailed(401, body: "x").category,
            "auth-failed"
        )
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.modelNotFound(404, body: "x").category,
            "model-not-found"
        )
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.timeout.category,
            "timeout"
        )
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.malformedResponse("x").category,
            "malformed-response"
        )
        XCTAssertEqual(
            AnthropicProvider.AnthropicError.networkFailed("x").category,
            "network-failed"
        )
    }

    /// 11: PR 36 contract — every description is prefixed with [ANTHROPIC_*].
    func testErrorDescription_hasStableTagPrefix() {
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.missingAPIKey("hint")
                .description.hasPrefix("[ANTHROPIC_MISSING_KEY]")
        )
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.authFailed(401, body: "x")
                .description.hasPrefix("[ANTHROPIC_AUTH_FAILED]")
        )
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.modelNotFound(404, body: "x")
                .description.hasPrefix("[ANTHROPIC_MODEL_NOT_FOUND]")
        )
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.timeout
                .description.hasPrefix("[ANTHROPIC_TIMEOUT]")
        )
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.malformedResponse("x")
                .description.hasPrefix("[ANTHROPIC_MALFORMED]")
        )
        XCTAssertTrue(
            AnthropicProvider.AnthropicError.networkFailed("x")
                .description.hasPrefix("[ANTHROPIC_NETWORK_FAILED]")
        )
    }
}
