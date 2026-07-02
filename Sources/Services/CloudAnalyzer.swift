import Foundation

struct CloudAnalyzer {
    let baseURL: URL
    let apiKey: String
    let model: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func enhance(_ analysis: FileAnalysis, text: String) async throws -> FileAnalysis {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: "You are a file organization assistant. Respond only with JSON containing keys: title, date (ISO8601 or empty), category, tags (array), source, summary, confidence (0-1)."),
                ChatMessage(role: "user", content: String(text.prefix(4000)))
            ],
            temperature: 0.2
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AnalysisError.cloudHTTPStatus(status)
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw AnalysisError.cloudDecodingFailed
        }
        return apply(json: content, to: analysis)
    }

    func apply(json: String, to analysis: FileAnalysis) -> FileAnalysis {
        let cleaned = cleanJSONContent(json)
        guard let data = cleaned.data(using: .utf8),
              let fields = try? JSONDecoder().decode(CloudFields.self, from: data) else {
            return analysis
        }
        var copy = analysis
        if let title = fields.title { copy.title = title }
        if let category = fields.category { copy.category = category }
        if let source = fields.source { copy.source = source }
        if let summary = fields.summary { copy.summary = summary }
        if let dateString = fields.date, !dateString.isEmpty,
           let parsed = ISO8601DateFormatter().date(from: dateString) {
            copy.date = parsed
        }
        if let tags = fields.tags { copy.tags = tags }
        if let confidence = fields.confidence { copy.confidence = confidence }
        return copy
    }

    /// 去除可能包裹在 JSON 外的 Markdown 代码围栏并裁剪空白。
    /// 支持 ` ```json\n{...}\n``` `、` ```json{...}``` ` 等常见形式。
    private func cleanJSONContent(_ content: String) -> String {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
            // 去掉可选的语言标记（如 json），直到第一个 JSON 开始字符 { 或 [。
            if let jsonStart = cleaned.firstIndex(where: { $0 == "{" || $0 == "[" }) {
                cleaned = String(cleaned[jsonStart...])
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

// MARK: - OpenAI 兼容 Chat Completions 的请求/响应模型

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: ChatMessage
    }
    let choices: [Choice]
}

/// 大模型返回的结构化标签，所有字段可选以容忍缺省。
private struct CloudFields: Decodable {
    let title: String?
    let date: String?
    let category: String?
    let tags: [String]?
    let source: String?
    let summary: String?
    let confidence: Double?
}
