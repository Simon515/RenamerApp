import Foundation

/// OpenAI 兼容端点配置（spec §2）。
public struct HTTPLLMConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
    }
}

/// OpenAI 兼容协议的 HTTP 实现：云端（DeepSeek/Kimi/OpenRouter/SiliconFlow）与本地（Ollama/LM Studio）同一接口。
public struct HTTPLLMProvider: Sendable {
    private let config: HTTPLLMConfig
    private let session: URLSession

    public init(config: HTTPLLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        var messages: [[String: String]] = [
            ["role": "system", "content": request.systemPrompt],
            ["role": "user", "content": request.userPrompt]
        ]
        if let hint = request.jsonSchemaHint {
            messages.append(["role": "system", "content": "请按如下 JSON 结构输出：\n\(hint)"])
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false
        ]
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = config.timeout
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        } catch {
            throw LLMProviderError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.http(status: http.statusCode, body: bodyString)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMProviderError.emptyContent
        }
        guard !content.isEmpty else { throw LLMProviderError.emptyContent }
        return LLMResponse(content: content)
    }
}