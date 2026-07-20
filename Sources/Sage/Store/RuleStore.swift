import Foundation

/// 规则库文件格式：带版本号，为将来迁移留余地（spec §10）。
public struct RuleLibrary: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var rules: [Rule] // 数组顺序即匹配优先级

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }
}

public enum RuleStoreError: LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "规则库文件版本 \(version) 高于当前应用支持的版本 \(RuleLibrary.currentVersion)，请升级 Sage。"
        }
    }
}

/// 规则库持久化（actor 串行读写）。
public actor RuleStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("rules.json")
    }

    public func load() throws -> RuleLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RuleLibrary(version: RuleLibrary.currentVersion, rules: [])
        }
        let data = try Data(contentsOf: fileURL)
        let library = try JSONDecoder().decode(RuleLibrary.self, from: data)
        guard library.version <= RuleLibrary.currentVersion else {
            throw RuleStoreError.unsupportedVersion(library.version)
        }
        return library
    }

    public func save(_ library: RuleLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }
}