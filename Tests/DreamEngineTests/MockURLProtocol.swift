import Foundation

/// Test helper: shared mock URLProtocol for intercepting URLSession requests
/// in unit tests. Pattern lifted from `LLMSchemaTests.swift` (P3-5) so any
/// provider test in this target can reuse the same harness without
/// duplicating the URLProtocol class-per-test-file.
///
/// Usage:
///   1. Create a URLSession with `URLSessionConfiguration.mockWithProtocol()`.
///   2. Set `MockURLProtocol.currentHandler = { req in (status, bodyJSON) }`.
///   3. Inspect `MockURLProtocol.lastRequest` / `lastRequestBodyJSON` after
///      the operation under test completes.
///
/// Thread-safety: state is guarded by `NSLock`. `@unchecked Sendable` is
/// the standard pattern for NSLock-backed state in Swift 6 (state is
/// internally synchronized; Swift compiler can't prove it).
public typealias MockURLProtocolHandler = (URLRequest) -> (statusCode: Int, bodyJSON: [String: Any])

final class MockURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentHandler: MockURLProtocolHandler?
    private var _lastRequest: URLRequest?
    private var _lastRequestBodyJSON: [String: Any] = [:]

    var currentHandler: MockURLProtocolHandler? {
        get { lock.withLock { _currentHandler } }
        set { lock.withLock { _currentHandler = newValue } }
    }

    var lastRequest: URLRequest? {
        get { lock.withLock { _lastRequest } }
        set { lock.withLock { _lastRequest = newValue } }
    }

    var lastRequestBodyJSON: [String: Any] {
        get { lock.withLock { _lastRequestBodyJSON } }
        set { lock.withLock { _lastRequestBodyJSON = newValue } }
    }
}

/// MockURLProtocol — intercepts URLSession requests, returns mock response,
/// records request path/body. State is static (class-shared) because
/// URLProtocol registration is class-based, not instance-based.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = MockURLProtocolState()

    /// Per-test handler. nil → default 200 + empty body.
    static var currentHandler: MockURLProtocolHandler? {
        get { state.currentHandler }
        set { state.currentHandler = newValue }
    }

    static var lastRequest: URLRequest? {
        get { state.lastRequest }
        set { state.lastRequest = newValue }
    }

    static var lastRequestBodyJSON: [String: Any] {
        get { state.lastRequestBodyJSON }
        set { state.lastRequestBodyJSON = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = self.request
        Self.lastRequest = req
        // Foundation may transfer httpBody to httpBodyStream when the
        // request goes through URLSession. Read either form so the body
        // is observable regardless of how Foundation materialized it.
        var bodyData = req.httpBody
        if bodyData == nil, let stream = req.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var chunks: [Data] = []
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            // Loop until read returns 0 or negative; hasBytesAvailable is
            // not reliable for one-shot request body streams.
            while true {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                chunks.append(Data(bytes: buffer, count: read))
            }
            bodyData = chunks.reduce(Data(), +)
        }
        if let bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            Self.lastRequestBodyJSON = json
        }
        let result = Self.currentHandler?(req) ?? (statusCode: 200, bodyJSON: [String: Any]())
        let response = HTTPURLResponse(
            url: req.url!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = (try? JSONSerialization.data(withJSONObject: result.bodyJSON)) ?? Data()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// Install MockURLProtocol on a URLSessionConfiguration for tests.
    static func mockWithProtocol() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return config
    }
}
