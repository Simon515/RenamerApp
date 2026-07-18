import XCTest
@testable import Sage

final class LLMGatewayTests: XCTestCase {
    private let nowDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeGateway(provider: LLMProvider, budget: Int? = nil, maxRetries: Int = 3) -> LLMGateway {
        let config = LLMGatewayConfig(budget: LLMBudget(dailyLimit: budget, date: nowDate),
                                      maxRetries: maxRetries)
        let captured = nowDate
        return LLMGateway(provider: provider, config: config, now: { captured })
    }

    func test语义判断返回解析() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.85}"#)
        let gateway = makeGateway(provider: provider)
        let verdict = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "hash1:cat")
        XCTAssertEqual(verdict, SemanticVerdict(matches: true, confidence: 0.85))
    }

    func test相同cacheKey只调一次() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        XCTAssertEqual(provider.calls, 1)
    }

    func test超预算抛错() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider, budget: 1)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k1")
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k2")
            XCTFail("应抛预算超限")
        } catch LLMGatewayError.budgetExceeded(let used, let limit) {
            XCTAssertEqual(used, 1)
            XCTAssertEqual(limit, 1)
        }
    }

    func test失败重试maxRetries次后抛错() async throws {
        struct Boom: Error {}
        let provider = FakeLLMProvider(throwing: Boom())
        let gateway = makeGateway(provider: provider, maxRetries: 2)
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
            XCTFail("应抛错")
        } catch LLMGatewayError.retriesExhausted {
            XCTAssertEqual(provider.calls, 2)
        }
    }

    func test解析失败抛parseFailed() async throws {
        let provider = FakeLLMProvider(content: "不是JSON")
        let gateway = makeGateway(provider: provider)
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
            XCTFail("应抛错")
        } catch LLMGatewayError.parseFailed {
            // ok
        }
    }
}