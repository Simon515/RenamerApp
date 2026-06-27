import Foundation
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var templates: [NamingTemplate] = SettingsViewModel.defaultTemplates
    var defaultTemplateID: UUID? = SettingsViewModel.defaultTemplates.first?.id
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

    /// 集中定义的默认命名模板，供任务编辑器和设置页共享。
    static let defaultTemplates: [NamingTemplate] = [
        NamingTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "默认", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}"),
        NamingTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "按日期", folderTemplate: "{date:yyyy}/{date:MM}", fileNameTemplate: "{title}"),
        NamingTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "按来源", folderTemplate: "{source}", fileNameTemplate: "{date}-{title}")
    ]

    /// 当前默认模板；若未找到则返回第一个模板。
    var defaultTemplate: NamingTemplate {
        templates.first { $0.id == defaultTemplateID }
            ?? templates.first
            ?? SettingsViewModel.defaultTemplates.first
            ?? NamingTemplate(id: UUID(), name: "默认", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
    }

    /// 根据当前输入构造云端配置；字段不完整时返回 nil。
    var cloudConfiguration: CloudConfiguration? {
        guard let url = URL(string: cloudBaseURL),
              !cloudBaseURL.isEmpty,
              !cloudAPIKey.isEmpty,
              !cloudModel.isEmpty else {
            return nil
        }
        return CloudConfiguration(baseURL: url, apiKey: cloudAPIKey, model: cloudModel)
    }

    init() {
        load()
    }

    func applyPreset(_ preset: (name: String, baseURL: String, model: String)) {
        cloudBaseURL = preset.baseURL
        cloudModel = preset.model
        save()
    }

    /// 将当前设置持久化到 Application Support 的 JSON 文件。
    /// 注意：API Key 目前以明文保存在应用沙箱目录中；后续应迁移到 Keychain。
    func save() {
        do {
            let payload = SettingsPayload(
                templates: templates,
                defaultTemplateID: defaultTemplateID,
                defaultOperation: defaultOperation,
                cloudBaseURL: cloudBaseURL,
                cloudAPIKey: cloudAPIKey,
                cloudModel: cloudModel
            )
            let data = try JSONEncoder().encode(payload)
            let url = Self.settingsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            // 设置保存失败不阻断主流程；可在后续版本加入日志。
        }
    }

    /// 从持久化存储加载设置；失败时保持默认值。
    func load() {
        do {
            let data = try Data(contentsOf: Self.settingsURL)
            let payload = try JSONDecoder().decode(SettingsPayload.self, from: data)
            templates = payload.templates.isEmpty ? SettingsViewModel.defaultTemplates : payload.templates
            defaultTemplateID = payload.defaultTemplateID ?? templates.first?.id
            defaultOperation = payload.defaultOperation
            cloudBaseURL = payload.cloudBaseURL
            cloudAPIKey = payload.cloudAPIKey
            cloudModel = payload.cloudModel
        } catch {
            // 无历史设置或解析失败时使用默认值。
        }
    }

    private static var settingsURL: URL {
        guard let supportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            return FileManager.default.temporaryDirectory.appending(path: "renamer_settings.json")
        }
        return supportURL.appending(path: "settings.json")
    }
}

private struct SettingsPayload: Codable {
    var templates: [NamingTemplate]
    var defaultTemplateID: UUID?
    var defaultOperation: CopyOrMove
    var cloudBaseURL: String
    var cloudAPIKey: String
    var cloudModel: String
}
