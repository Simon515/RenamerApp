import Foundation
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var templates: [NamingTemplate] = []
    var defaultOperation: CopyOrMove = .copy
    var cloudBaseURL: String = ""
    var cloudAPIKey: String = ""
    var cloudModel: String = ""

    let providerPresets: [(name: String, baseURL: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
        ("Kimi", "https://api.moonshot.cn", "moonshot-v1-8k"),
        ("OpenRouter", "https://openrouter.ai/api", "openai/gpt-4o"),
        ("SiliconFlow", "https://api.siliconflow.cn", "Qwen/Qwen2-7B-Instruct")
    ]

    func applyPreset(_ preset: (name: String, baseURL: String, model: String)) {
        cloudBaseURL = preset.baseURL
        cloudModel = preset.model
    }
}
