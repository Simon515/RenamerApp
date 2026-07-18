import Foundation

/// LLM（或本地提取）产出的元数据，供模板令牌引用（spec §4 LLM 动作）。
public struct ExtractedMetadata: Codable, Sendable, Equatable {
    public var title: String?
    public var date: Date?
    public var category: String?
    public var tags: [String]
    public var summary: String?
    public var source: String?

    public init(title: String? = nil, date: Date? = nil, category: String? = nil,
                tags: [String] = [], summary: String? = nil, source: String? = nil) {
        self.title = title
        self.date = date
        self.category = category
        self.tags = tags
        self.summary = summary
        self.source = source
    }
}

/// 命名模板解析：令牌替换 + 逐段文件名清洗。
/// 关键语义：模板级的 "/" 是子目录分隔符；令牌值内（含 {date:…} 格式串内）的 "/" 是数据，清洗为 "-"。
public struct TemplateResolver: Sendable {
    public init() {}

    public func resolve(_ template: String, metadata: ExtractedMetadata, fallbackName: String) -> String {
        // 1) 保护令牌：把 {…} 暂存为不含 "/" 的占位符，避免 {date:yyyy/MM} 这类格式串被误切段
        var protected = template
        var tokens: [String: String] = [:]
        var index = 0
        while let range = protected.range(of: #"\{[^}]*\}"#, options: .regularExpression) {
            let key = "\u{1}\(index)\u{1}"
            tokens[key] = String(protected[range])
            protected.replaceSubrange(range, with: key)
            index += 1
        }
        // 2) 按模板级 "/" 切段；3) 段内还原令牌、替换值、清洗
        return protected.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                var restored = String(segment)
                for (key, token) in tokens {
                    restored = restored.replacingOccurrences(of: key, with: token)
                }
                let substituted = substitute(restored, metadata: metadata, fallbackName: fallbackName)
                return sanitize(substituted)
            }
            .joined(separator: "/")
    }

    private func substitute(_ segment: String, metadata: ExtractedMetadata, fallbackName: String) -> String {
        var result = segment
        result = result.replacingOccurrences(of: "{title}", with: metadata.title ?? fallbackName)
        result = result.replacingOccurrences(of: "{category}", with: metadata.category ?? "")
        result = result.replacingOccurrences(of: "{source}", with: metadata.source ?? "")
        // {date:格式} 与 {date}
        while let range = result.range(of: #"\{date(:[^}]+)?\}"#, options: .regularExpression) {
            let token = String(result[range])
            let format: String
            if token == "{date}" {
                format = "yyyy-MM-dd"
            } else {
                format = String(token.dropFirst("{date:".count).dropLast())
            }
            result.replaceSubrange(range, with: formatted(metadata.date, format: format))
        }
        return result
    }

    private func formatted(_ date: Date?, format: String) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// 文件名单段清洗：路径分隔符与冒号替换为 "-"。
    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}