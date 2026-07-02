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
    /// Keychain 相关操作的错误提示（如写入失败），供 UI 展示。
    var keychainError: String?

    private static let keychain = KeychainStore(service: "com.renamer.credentials")
    private static let apiKeyAccount = "cloud-api-key"

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

    /// 将当前设置持久化：API Key 存入 Keychain，其余字段存入 Application Support 的 JSON。
    func save() {
        // API Key 写入 Keychain；失败不中断其它设置保存，仅记录错误供 UI 展示。
        do {
            if cloudAPIKey.isEmpty {
                try Self.keychain.delete(account: Self.apiKeyAccount)
            } else {
                try Self.keychain.write(account: Self.apiKeyAccount, value: cloudAPIKey)
            }
            keychainError = nil
        } catch {
            Log.settings.error("API Key 写入 Keychain 失败：\(error.localizedDescription, privacy: .public)")
            keychainError = error.localizedDescription
        }

        do {
            // JSON 中不再包含 API Key。
            let payload = SettingsPayload(
                templates: templates,
                defaultTemplateID: defaultTemplateID,
                defaultOperation: defaultOperation,
                cloudBaseURL: cloudBaseURL,
                cloudModel: cloudModel
            )
            let data = try JSONEncoder().encode(payload)
            let url = Self.settingsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            Log.settings.error("设置保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 从持久化存储加载设置；失败时保持默认值。
    /// 首次运行若检测到旧版 JSON 中的明文 API Key，则迁移到 Keychain 并重写 JSON 清除明文。
    func load() {
        var payloadCloudBaseURL = ""
        var payloadCloudModel = ""
        var legacyPlaintextKey: String?

        do {
            let data = try Data(contentsOf: Self.settingsURL)
            // 用兼容旧字段的 payload 解码，以便读取可能存在的遗留明文 key。
            let payload = try JSONDecoder().decode(LegacySettingsPayload.self, from: data)
            templates = (payload.templates?.isEmpty ?? true) ? SettingsViewModel.defaultTemplates : payload.templates!
            defaultTemplateID = payload.defaultTemplateID ?? templates.first?.id
            defaultOperation = payload.defaultOperation ?? .copy
            payloadCloudBaseURL = payload.cloudBaseURL ?? ""
            payloadCloudModel = payload.cloudModel ?? ""
            legacyPlaintextKey = payload.cloudAPIKey
        } catch {
            // 无历史设置或解析失败时使用默认值。
        }

        cloudBaseURL = payloadCloudBaseURL
        cloudModel = payloadCloudModel

        // 优先从 Keychain 读取 API Key。
        let keychainKey = (try? Self.keychain.read(account: Self.apiKeyAccount)) ?? nil
        if let keychainKey, !keychainKey.isEmpty {
            cloudAPIKey = keychainKey
        } else if let legacyPlaintextKey, !legacyPlaintextKey.isEmpty {
            // 迁移：写入 Keychain，随后 save() 会重写 JSON（新格式无 key 字段），清除明文。
            cloudAPIKey = legacyPlaintextKey
            Log.settings.info("检测到旧版明文 API Key，正在迁移到 Keychain")
            save()
        }
    }

    private static var settingsURL: URL {
        guard let supportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            return FileManager.default.temporaryDirectory.appending(path: "renamer_settings.json")
        }
        return supportURL.appending(path: "Renamer/settings.json")
    }
}

/// 当前设置持久化格式（不含 API Key，key 存于 Keychain）。
private struct SettingsPayload: Codable {
    var templates: [NamingTemplate]
    var defaultTemplateID: UUID?
    var defaultOperation: CopyOrMove
    var cloudBaseURL: String
    var cloudModel: String
}

/// 兼容旧版格式的解码用 payload：全部字段可选，用于读取可能存在的遗留明文 `cloudAPIKey`。
private struct LegacySettingsPayload: Decodable {
    var templates: [NamingTemplate]?
    var defaultTemplateID: UUID?
    var defaultOperation: CopyOrMove?
    var cloudBaseURL: String?
    var cloudAPIKey: String?
    var cloudModel: String?
}
