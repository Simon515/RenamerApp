import Foundation
@testable import Sage

/// 测试用 LLM Provider：注入固定响应或抛错，记录调用情况，可选注入延迟以模拟挂起点并发。
final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    enum Mode {
        case returnContent(String)
        case throwError(Error)
    }

    private let mode: Mode
    private let delay: TimeInterval
    private let lock = NSLock()
    private var _calls = 0
    private var _concurrent = 0
    private var _maxConcurrent = 0
    private var _lastRequest: LLMRequest?
    private var _callTimes: [Date] = []

    init(content: String, delay: TimeInterval = 0) {
        self.mode = .returnContent(content)
        self.delay = delay
    }
    init(throwing error: Error, delay: TimeInterval = 0) {
        self.mode = .throwError(error)
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    var lastRequest: LLMRequest? { lock.withLock { _lastRequest } }
    var callTimes: [Date] { lock.withLock { _callTimes } }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock {
            _calls += 1
            _concurrent += 1
            _maxConcurrent = max(_maxConcurrent, _concurrent)
            _lastRequest = request
            _callTimes.append(Date())
        }
        defer { lock.withLock { _concurrent -= 1 } }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        switch mode {
        case .returnContent(let content):
            return LLMResponse(content: content)
        case .throwError(let error):
            throw error
        }
    }
}
