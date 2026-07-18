import Foundation

/// OpenAI 兼容协议抽象：云端与本地端点同一接口（spec §2、§3 LLM 模块）。
/// 真实实现 `HTTPLLMProvider` 在第 3 份计划任务；本协议是 Gateway 唯一依赖。
public protocol LLMProvider: Sendable {
    func send(_ request: LLMRequest) async throws -> LLMResponse
}