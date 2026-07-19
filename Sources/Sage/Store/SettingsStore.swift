import Foundation

public enum SettingsStoreError: LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "设置文件版本 \(v) 高于当前应用支持的版本 \(SageSettings.currentVersion)，请升级 Sage。"
        }
    }
}

/// 设置持久化（actor：串行读写）。
public actor SettingsStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("settings.json")
        self.fileManager = fileManager
    }

    public func load() throws -> SageSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .defaults }
        let settings = try JSONDecoder().decode(SageSettings.self, from: Data(contentsOf: fileURL))
        guard settings.version <= SageSettings.currentVersion else {
            throw SettingsStoreError.unsupportedVersion(settings.version)
        }
        return settings
    }

    public func save(_ settings: SageSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
