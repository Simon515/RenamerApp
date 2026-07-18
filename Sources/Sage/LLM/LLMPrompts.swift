import Foundation

/// LLM prompt 模板：语义判断 / 元数据提取 / 命名。
/// 实际字符串内容可由 UI 设置调整；这里给默认结构化模板。
public enum LLMPrompts {
    /// 内容是否属于某分类（返回 {matches, confidence}）。
    public static func belongsTo(category: String, text: String) -> LLMRequest {
        let system = "你是文件分类助手。判断给定文件文本是否属于指定分类，返回 JSON。"
        let user = "分类：「\(category)」\n文件文本：\n\(text.prefix(2000))"
        let hint = #"{"matches": true|false, "confidence": 0.0-1.0}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }

    /// 内容是否符自然语言描述（返回 {matches, confidence}）。
    public static func matchesDescription(description: String, text: String) -> LLMRequest {
        let system = "你是文件内容匹配助手。判断给定文件文本是否符自然语言描述，返回 JSON。"
        let user = "描述：「\(description)」\n文件文本：\n\(text.prefix(2000))"
        let hint = #"{"matches": true|false, "confidence": 0.0-1.0}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }

    /// 元数据提取（返回 ExtractedMetadata JSON）。
    public static func extractMetadata(text: String, fallbackName: String) -> LLMRequest {
        let system = "你是文件元数据提取助手。从文件文本中提取标题、日期、分类、标签、摘要、来源。"
        let user = "文件名（备用标题）：\(fallbackName)\n文件文本：\n\(text.prefix(4000))"
        let hint = #"{"title": String|null, "date": "yyyy-MM-dd"|null, "category": String|null, "tags": [String], "summary": String|null, "source": String|null}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }
}