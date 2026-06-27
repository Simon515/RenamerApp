import Foundation

struct CloudAnalyzer {
    let baseURL: URL
    let apiKey: String
    let model: String

    func enhance(_ analysis: FileAnalysis, text: String) async throws -> FileAnalysis {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a file organization assistant. Respond only with JSON containing keys: title, date (ISO8601 or empty), category, tags (array), source, summary, confidence (0-1)."],
                ["role": "user", "content": text.prefix(4000)]
            ],
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return analysis
        }
        var copy = analysis
        copy.title = obj["title"] as? String ?? copy.title
        copy.category = obj["category"] as? String ?? copy.category
        copy.source = obj["source"] as? String ?? copy.source
        copy.summary = obj["summary"] as? String ?? copy.summary
        if let dateString = obj["date"] as? String, !dateString.isEmpty {
            let formatter = ISO8601DateFormatter()
            copy.date = formatter.date(from: dateString)
        }
        if let tags = obj["tags"] as? [String] { copy.tags = tags }
        if let conf = obj["confidence"] as? Double { copy.confidence = conf }
        return copy
    }
}
