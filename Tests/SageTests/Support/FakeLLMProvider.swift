import Foundation
@testable import Sage

/// 测试用 LLM Provider：注入固定响应或抛错，记录调用情况。
final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    enum Mode {
        case returnContent(String)
        case throwError(Error)
    }

    private let mode: Mode
    private(set) var calls = 0
    private(set) var lastRequest: LLMRequest?

    init(content: String) { self.mode = .returnContent(content) }
    init(throwing error: Error) { self.mode = .throwError(error) }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        calls += 1
        lastRequest = request
        switch mode {
        case .returnContent(let content):
            return LLMResponse(content: content)
        case .throwError(let error):
            throw error
        }
    }
}