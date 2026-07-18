import XCTest
@testable import Sage

/// 拦截 URLSession 的自定义 URLProtocol，返回注入的响应。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (HTTPURLResponse, Data)?
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let (response, data) = Self.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { response = nil; error = nil }
}

final class HTTPLLMProviderTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() { StubURLProtocol.reset() }

    private func makeConfig() -> HTTPLLMConfig {
        HTTPLLMConfig(baseURL: URL(string: "https://api.example.com/v1")!,
                      apiKey: "sk-test", model: "test-model")
    }

    func test成功返回content() async throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                    Data(json.utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        let response = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
        XCTAssertEqual(response.content, "hello")
    }

    func testHTTP非2xx抛错() async throws {
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 401, httpVersion: nil, headerFields: nil)!,
                                    Data("unauthorized".utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
            XCTFail("应抛错")
        } catch LLMProviderError.http(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    func test空content抛错() async throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                    Data(json.utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
            XCTFail("应抛错")
        } catch LLMProviderError.emptyContent {
            // ok
        }
    }
}