import XCTest
@testable import Sage

final class LLMGatewayTests: XCTestCase {
    private let nowDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeGateway(provider: LLMProvider, budget: Int? = nil, maxRetries: Int = 3,
                             minInterval: TimeInterval = 0) -> LLMGateway {
        let config = LLMGatewayConfig(budget: LLMBudget(dailyLimit: budget, date: nowDate),
                                      minRetryDelay: 0,  // 测试不真实等待
                                      maxRetries: maxRetries,
                                      minInterval: minInterval)
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

    // MARK: - 预算并发（TOCTOU 修复）

    func test并发不同cacheKey_provider调用数不超预算() async throws {
        let limit = 3
        // 注入延迟使所有请求同时抵达挂起点，考验原子额度占用。
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#, delay: 0.1)
        let gateway = makeGateway(provider: provider, budget: limit)
        let total = 10
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    _ = try? await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k\(i)")
                }
            }
        }
        XCTAssertLessThanOrEqual(provider.calls, limit, "并发不应超支：实际 provider 调用数须 ≤ 预算")
        XCTAssertEqual(provider.calls, limit, "应恰好用满预算")
    }

    // MARK: - 限速

    func test限速_两次未命中缓存调用间有最小间隔() async throws {
        let interval: TimeInterval = 0.2
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider, minInterval: interval)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k1")
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k2")
        let times = provider.callTimes
        XCTAssertEqual(times.count, 2)
        let gap = times[1].timeIntervalSince(times[0])
        XCTAssertGreaterThanOrEqual(gap, interval * 0.75, "两次真实调用间隔应接近 minInterval")
    }

    func test限速_缓存命中不计入限速() async throws {
        let interval: TimeInterval = 0.5
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider, minInterval: interval)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        let start = Date()
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")  // 命中缓存
        XCTAssertLessThan(Date().timeIntervalSince(start), interval * 0.5, "缓存命中不应被限速阻塞")
        XCTAssertEqual(provider.calls, 1)
    }

    // MARK: - 重试可重试性

    func testHTTP4xx不重试() async throws {
        let provider = FakeLLMProvider(throwing: LLMProviderError.http(status: 401, body: "unauthorized"))
        let gateway = makeGateway(provider: provider, maxRetries: 3)
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
            XCTFail("应抛错")
        } catch LLMGatewayError.retriesExhausted {
            XCTAssertEqual(provider.calls, 1, "4xx 非瞬态错误不应重试")
        }
    }

    func testHTTP5xx与429重试() async throws {
        let provider500 = FakeLLMProvider(throwing: LLMProviderError.http(status: 503, body: ""))
        let gateway500 = makeGateway(provider: provider500, maxRetries: 3)
        _ = try? await gateway500.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        XCTAssertEqual(provider500.calls, 3, "5xx 应重试至上限")

        let provider429 = FakeLLMProvider(throwing: LLMProviderError.http(status: 429, body: ""))
        let gateway429 = makeGateway(provider: provider429, maxRetries: 2)
        _ = try? await gateway429.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        XCTAssertEqual(provider429.calls, 2, "429 应重试")
    }

    func test调用失败回退预算额度() async throws {
        // 首个请求失败应释放额度，使后续成功请求仍在预算内。
        let failing = FakeLLMProvider(throwing: LLMProviderError.http(status: 500, body: ""))
        let gateway = makeGateway(provider: failing, budget: 1, maxRetries: 1)
        _ = try? await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k1")
        // 预算已回退：再次调用不应因预算耗尽而立刻抛 budgetExceeded。
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k2")
            XCTFail("provider 仍失败，应抛 retriesExhausted 而非 budgetExceeded")
        } catch LLMGatewayError.retriesExhausted {
            // ok：说明额度已回退，请求得以再次尝试真实调用
        } catch LLMGatewayError.budgetExceeded {
            XCTFail("失败调用未回退预算额度")
        }
    }

    func test缺省confidence视为1() async throws {
        // 模型返回 matches:true 但无 confidence 字段，不应被 minConfidence 阈值判否。
        let provider = FakeLLMProvider(content: #"{"matches":true}"#)
        let gateway = makeGateway(provider: provider)
        let verdict = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        XCTAssertTrue(verdict.matches)
        XCTAssertEqual(verdict.confidence, 1.0, accuracy: 0.0001)
    }
}