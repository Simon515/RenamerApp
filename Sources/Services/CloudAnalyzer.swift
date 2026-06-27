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

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a file organization assistant. Respond only with JSON containing keys: title, date (ISO8601 or empty), category, tags (array), source, summary, confidence (0-1)."],
                ["role": "user", "content": String(text.prefix(4000))]
            ],
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AnalysisError.cloudHTTPStatus(status)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AnalysisError.cloudDecodingFailed
        }
        return apply(json: content, to: analysis)
    }

    func apply(json: String, to analysis: FileAnalysis) -> FileAnalysis {
        let cleaned = cleanJSONContent(json)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return analysis
        }
        var copy = analysis
        copy.title = obj["title"] as? String ?? copy.title
        copy.category = obj["category"] as? String ?? copy.category
        copy.source = obj["source"] as? String ?? copy.source
        copy.summary = obj["summary"] as? String ?? copy.summary
        if let dateString = obj["date"] as? String, !dateString.isEmpty,
           let parsed = ISO8601DateFormatter().date(from: dateString) {
            copy.date = parsed
        }
        if let tags = obj["tags"] as? [String] { copy.tags = tags }
        if let conf = obj["confidence"] as? Double { copy.confidence = conf }
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
