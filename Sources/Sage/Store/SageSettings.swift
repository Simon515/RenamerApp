import Foundation

/// LLM 端点配置（API Key 不在此，存 Keychain）。
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var timeoutSeconds: Double

    public init(enabled: Bool, baseURL: String, model: String, timeoutSeconds: Double) {
        self.enabled = enabled; self.baseURL = baseURL; self.model = model; self.timeoutSeconds = timeoutSeconds
    }
}

/// 应用设置（持久化到 settings.json）。
public struct SageSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var monitoringEnabled: Bool
    public var launchAtLogin: Bool
    public var dailyLLMBudget: Int?
    public var provider: ProviderSettings

    public init(version: Int, monitoringEnabled: Bool, launchAtLogin: Bool,
                dailyLLMBudget: Int?, provider: ProviderSettings) {
        self.version = version; self.monitoringEnabled = monitoringEnabled
        self.launchAtLogin = launchAtLogin; self.dailyLLMBudget = dailyLLMBudget; self.provider = provider
    }

    public static var defaults: SageSettings {
        SageSettings(version: currentVersion, monitoringEnabled: true, launchAtLogin: false,
                     dailyLLMBudget: nil,
                     provider: ProviderSettings(enabled: false, baseURL: "", model: "", timeoutSeconds: 30))
    }
}
