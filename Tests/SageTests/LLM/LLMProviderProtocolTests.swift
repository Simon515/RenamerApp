import XCTest
@testable import Sage

final class LLMProviderProtocolTests: XCTestCase {
    func testFake返回内容() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.8}"#)
        let response = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u", jsonSchemaHint: nil))
        XCTAssertEqual(response.content, #"{"matches":true,"confidence":0.8}"#)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(provider.lastRequest?.userPrompt, "u")
    }

    func testFake抛错() async throws {
        struct Boom: Error {}
        let provider = FakeLLMProvider(throwing: Boom())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u", jsonSchemaHint: nil))
            XCTFail("应抛错")
        } catch is Boom {
            // ok
        }
    }

    func testProviderError描述() {
        XCTAssertEqual(LLMProviderError.timeout.errorDescription, "LLM 请求超时。")
        XCTAssertEqual(LLMProviderError.emptyContent.errorDescription, "LLM 返回内容为空。")
    }
}