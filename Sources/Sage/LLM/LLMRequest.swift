import Foundation

/// LLM 请求载体（OpenAI 兼容，不绑定具体厂商）。
public struct LLMRequest: Sendable {
    public var systemPrompt: String
    public var userPrompt: String
    public var jsonSchemaHint: String?  // 提示模型按 JSON 输出；为 nil 则自由文本

    public init(systemPrompt: String, userPrompt: String, jsonSchemaHint: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.jsonSchemaHint = jsonSchemaHint
    }
}

/// LLM 原始返回（未解析的文本）。
public struct LLMResponse: Sendable, Equatable {
    public var content: String
    public init(content: String) { self.content = content }
}

/// LLM 调用错误。
public enum LLMProviderError: LocalizedError, Sendable {
    case network(Error)
    case http(status: Int, body: String)
    case emptyContent
    case timeout

    public var errorDescription: String? {
        switch self {
        case .network:
            return "LLM 网络请求失败。"
        case .http(let status, _):
            return "LLM 服务返回 HTTP \(status)。"
        case .emptyContent:
            return "LLM 返回内容为空。"
        case .timeout:
            return "LLM 请求超时。"
        }
    }
}