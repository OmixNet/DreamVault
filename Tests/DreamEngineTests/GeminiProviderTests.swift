import XCTest
@testable import DreamEngine

/// v0.6 PR 36: GeminiProvider unit tests.
///
/// Coverage mirrors PR 28 / PR 34 / PR 36 Anthropic tests:
///   1. request shape: POST /v1beta/models/{model}:generateContent +
///      Content-Type + x-goog-api-key
///   2. 200 + typical Gemini response → first text part
///   3. HTTP 401 → `.authFailed(401, body: ...)` (with `[GEMINI_AUTH_FAILED]` tag)
///   4. HTTP 404 → `.modelNotFound(404, body: ...)` (with `[GEMINI_MODEL_NOT_FOUND]` tag)
///   5. HTTP 500 → `.networkFailed("HTTP 500: ...")`
///   6. URLError.timedOut → `.timeout`
///   7. URLError.notConnectedToInternet → `.networkFailed(...)`
///   8. malformed response (no text part) → `.malformedResponse`
///   9. missing API key → `.missingAPIKey`, NO HTTP request issued
///  10. security invariant: apiKey VALUE never appears in error description
///  11. error category stability (6 cases, same shape as PR 34 / PR 36)
///  12. v0.6 PR 36 contract: every error description is prefixed with
///      a stable `[GEMINI_*]` tag
///  13. URL contract: `:generateContent` literal colon is preserved
///      (NOT percent-encoded to %3A)
final class GeminiProviderTests: XCTestCase {

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

    /// Standard Gemini generateContent success response.
    private func geminiSuccessResponse(text: String) -> [String: Any] {
        return [
            "candidates": [
                [
                    "content": [
                        "role": "model",
                        "parts": [["text": text]],
                    ],
                    "finishReason": "STOP",
                ],
            ],
        ]
    }

    // MARK: - Tests

    /// 1 + 2: request shape + happy path. Verifies the Gemini-specific
    /// HTTP request shape (POST /v1beta/models/{model}:generateContent +
    /// x-goog-api-key) and extracts the first text part from a typical
    /// Gemini response.
    func testComplete_happyPath_sendsCorrectRequestAndParsesText() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (200, self.geminiSuccessResponse(text: "YES"))
        }

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "AIza-test-key",
            session: session
        )
        let result = try await provider.complete(system: "sys", user: "usr")
        XCTAssertEqual(result, "YES")

        // Request shape: POST /v1beta/models/{model}:generateContent
        // + Content-Type + x-goog-api-key.
        let req = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1beta/models/gemini-2.0-flash:generateContent")
        // Colon must be preserved as a literal, NOT percent-encoded.
        XCTAssertFalse(req.url?.absoluteString.contains("%3A") ?? true,
                        "URL must preserve `:generateContent` literal, not percent-encode: \(req.url?.absoluteString ?? "")")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test-key")
        // No Bearer auth.
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))

        // Body shape: { systemInstruction: { parts: [{text}] }, contents: [{role, parts: [{text}]}] }
        let body = MockURLProtocol.lastRequestBodyJSON
        XCTAssertFalse(body.isEmpty, "body must be captured (via stream)")
        let system = body["systemInstruction"] as? [String: Any]
        let systemParts = system?["parts"] as? [[String: Any]]
        XCTAssertEqual(systemParts?.count, 1, "systemInstruction is top-level")
        XCTAssertEqual(systemParts?[0]["text"] as? String, "sys")
        let contents = body["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1, "contents has only user turn (system is top-level)")
        XCTAssertEqual(contents?[0]["role"] as? String, "user")
        let parts = contents?[0]["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?[0]["text"] as? String, "usr")
    }

    /// 3: HTTP 401 → `.authFailed(401, body: ...)` with stable tag.
    func testComplete_http401_throwsAuthFailed() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (401, ["error": ["message": "API key not valid"]])
        }

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "AIza-bad-key",
            session: session
        )

        do {
            _ = try await provider.complete(system: "sys", user: "usr")
            XCTFail("expected throw on 401")
        } catch let GeminiProvider.GeminiError.authFailed(code, body) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("API key not valid"))
            XCTAssertFalse(body.contains("AIza-bad-key"),
                            "apiKey value must not leak: \(body)")
            let desc = GeminiProvider.GeminiError
                .authFailed(code, body: body).description
            XCTAssertTrue(desc.hasPrefix("[GEMINI_AUTH_FAILED]"),
                          "description must start with [GEMINI_AUTH_FAILED] tag: \(desc)")
        } catch {
            XCTFail("expected .authFailed, got \(error)")
        }
    }

    /// 4: HTTP 404 → `.modelNotFound(404, body: ...)` with stable tag.
    func testComplete_http404_throwsModelNotFound() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        MockURLProtocol.currentHandler = { _ in
            (404, ["error": ["message": "models/gemini-bogus not found"]])
        }

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-bogus",
            apiKey: "AIza-test",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on 404")
        } catch let GeminiProvider.GeminiError.modelNotFound(code, _) {
            XCTAssertEqual(code, 404)
            let desc = GeminiProvider.GeminiError
                .modelNotFound(code, body: "x").description
            XCTAssertTrue(desc.hasPrefix("[GEMINI_MODEL_NOT_FOUND]"),
                          "description must start with [GEMINI_MODEL_NOT_FOUND] tag: \(desc)")
        } catch {
            XCTFail("expected .modelNotFound, got \(error)")
        }
    }

    /// 5: 200 but malformed response (no text part) → `.malformedResponse`.
    func testComplete_malformedResponse_throwsMalformed() async throws {
        let (session, cleanup) = makeMockSession()
        defer { cleanup() }

        // 200 with no candidates[0].content.parts
        MockURLProtocol.currentHandler = { _ in
            (200, ["candidates": [["content": ["role": "model", "parts": []]]]])
        }

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "AIza-test",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on malformed response")
        } catch GeminiProvider.GeminiError.malformedResponse {
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

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "AIza-test",
            session: timeoutSession
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on timeout")
        } catch GeminiProvider.GeminiError.timeout {
            let desc = GeminiProvider.GeminiError.timeout.description
            XCTAssertTrue(desc.hasPrefix("[GEMINI_TIMEOUT]"),
                          "description must start with [GEMINI_TIMEOUT] tag: \(desc)")
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

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "AIza-test",
            session: transportSession
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on transport error")
        } catch GeminiProvider.GeminiError.networkFailed {
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

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on missing apiKey")
        } catch let GeminiProvider.GeminiError.missingAPIKey(hint) {
            XCTAssertTrue(hint.contains("DREAMFORGE_LLM_API_KEY"),
                          "hint should mention the env var: \(hint)")
            let desc = GeminiProvider.GeminiError
                .missingAPIKey(hint).description
            XCTAssertTrue(desc.hasPrefix("[GEMINI_MISSING_KEY]"),
                          "description must start with [GEMINI_MISSING_KEY] tag: \(desc)")
        } catch {
            XCTFail("expected .missingAPIKey, got \(error)")
        }

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

        let provider = GeminiProvider(
            baseURL: URL(string: "https://test.invalid")!,
            model: "gemini-2.0-flash",
            apiKey: "SECRET-LEAK-12345",
            session: session
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("expected throw on 500")
        } catch let GeminiProvider.GeminiError.networkFailed(detail) {
            XCTAssertTrue(detail.contains("HTTP 500"))
            XCTAssertEqual(detail.components(separatedBy: "SECRET-LEAK-12345").count - 1, 1)

            let desc = GeminiProvider.GeminiError
                .networkFailed(detail).description
            XCTAssertTrue(desc.hasPrefix("[GEMINI_NETWORK_FAILED]"),
                          "description must start with [GEMINI_NETWORK_FAILED] tag: \(desc)")
        } catch {
            XCTFail("expected .networkFailed, got \(error)")
        }
    }

    /// 10: error category stability — same 6 values as PR 34 / PR 36.
    func testErrorCategory_isStableAcrossCases() {
        XCTAssertEqual(
            GeminiProvider.GeminiError.missingAPIKey("hint").category,
            "missing-api-key"
        )
        XCTAssertEqual(
            GeminiProvider.GeminiError.authFailed(401, body: "x").category,
            "auth-failed"
        )
        XCTAssertEqual(
            GeminiProvider.GeminiError.modelNotFound(404, body: "x").category,
            "model-not-found"
        )
        XCTAssertEqual(
            GeminiProvider.GeminiError.timeout.category,
            "timeout"
        )
        XCTAssertEqual(
            GeminiProvider.GeminiError.malformedResponse("x").category,
            "malformed-response"
        )
        XCTAssertEqual(
            GeminiProvider.GeminiError.networkFailed("x").category,
            "network-failed"
        )
    }

    /// 11: PR 36 contract — every description is prefixed with [GEMINI_*].
    func testErrorDescription_hasStableTagPrefix() {
        XCTAssertTrue(
            GeminiProvider.GeminiError.missingAPIKey("hint")
                .description.hasPrefix("[GEMINI_MISSING_KEY]")
        )
        XCTAssertTrue(
            GeminiProvider.GeminiError.authFailed(401, body: "x")
                .description.hasPrefix("[GEMINI_AUTH_FAILED]")
        )
        XCTAssertTrue(
            GeminiProvider.GeminiError.modelNotFound(404, body: "x")
                .description.hasPrefix("[GEMINI_MODEL_NOT_FOUND]")
        )
        XCTAssertTrue(
            GeminiProvider.GeminiError.timeout
                .description.hasPrefix("[GEMINI_TIMEOUT]")
        )
        XCTAssertTrue(
            GeminiProvider.GeminiError.malformedResponse("x")
                .description.hasPrefix("[GEMINI_MALFORMED]")
        )
        XCTAssertTrue(
            GeminiProvider.GeminiError.networkFailed("x")
                .description.hasPrefix("[GEMINI_NETWORK_FAILED]")
        )
    }
}
