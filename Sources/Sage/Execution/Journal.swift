import Foundation

public struct JournalFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var records: [JournalRecord]
    public init(version: Int, records: [JournalRecord]) { self.version = version; self.records = records }
}

public enum JournalError: LocalizedError {
    case recordNotFound
    case cannotRollbackTrash
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound: return "找不到要回滚的操作记录。"
        case .cannotRollbackTrash: return "该文件已移入废纸篓且无记录的废纸篓路径，无法自动回滚，请手动从废纸篓恢复。"
        case .rollbackFailed(let msg): return "回滚失败：\(msg)"
        }
    }
}

/// DT 操作的回滚执行（真实实现为 DTActions；nil 表示 DT 回滚不可用）。
public protocol DTReverting: Sendable {
    func revert(_ op: ReversibleOp) async throws
}

/// 操作日志（actor：串行读写 + 回滚）。
public actor Journal {
    private let fileURL: URL
    private let fileManager: FileManager
    private let maxRecords: Int
    private let dtReverter: (any DTReverting)?

    public init(directory: URL, fileManager: FileManager = .default, maxRecords: Int = 500,
                dtReverter: (any DTReverting)? = nil) {
        self.fileURL = directory.appendingPathComponent("journal.json")
        self.fileManager = fileManager
        self.maxRecords = maxRecords
        self.dtReverter = dtReverter
    }

    public func append(_ record: JournalRecord) throws {
        var file = try load()
        file.records.append(record)
        if file.records.count > maxRecords {
            file.records.removeFirst(file.records.count - maxRecords)
        }
        try save(file)
    }

    /// 时间倒序（最新在前）。
    public func all() throws -> [JournalRecord] {
        try load().records.sorted { $0.timestamp > $1.timestamp }
    }

    public func rollback(id: UUID) async throws {
        var file = try load()
        guard let index = file.records.firstIndex(where: { $0.id == id }) else {
            throw JournalError.recordNotFound
        }
        let record = file.records[index]
        for op in record.ops.reversed() {
            switch op {
            case .dtImported, .dtRenamed, .dtAddedTags, .dtMoved:
                guard let dtReverter else {
                    throw JournalError.rollbackFailed("DEVONthink 回滚不可用")
                }
                try await dtReverter.revert(op)
            default:
                try revert(op)
            }
        }
        file.records.remove(at: index)
        try save(file)
    }

    private func revert(_ op: ReversibleOp) throws {
        switch op {
        case .moved(let from, let to), .renamed(let from, let to):
            try moveBack(from: to, to: from)
        case .copied(let to):
            if fileManager.fileExists(atPath: to) { try fileManager.removeItem(atPath: to) }
        case .trashed(let originalPath, let trashPath):
            guard let trashPath else { throw JournalError.cannotRollbackTrash }
            try moveBack(from: trashPath, to: originalPath)
        case .addedFinderTags(_, let path, let previous):
            // `URLResourceValues.tagNames` 的 setter 在 macOS 26 之前不可用，
            // 故直接写 `com.apple.metadata:_kMDItemUserTags`（与 LocalActionExecutor 一致，兼容 macOS 14+）。
            try? writeFinderTags(previous, to: path)
        case .dtImported, .dtRenamed, .dtAddedTags, .dtMoved:
            // DT 操作在 rollback(id:) 中已分派给 dtReverter，不应到达此处
            throw JournalError.rollbackFailed("内部错误：DT 操作应由 dtReverter 处理")
        }
    }

    private func writeFinderTags(_ tags: [String], to path: String) throws {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, data.count, 0, 0)
        }
        if result != 0 {
            throw JournalError.rollbackFailed(String(cString: strerror(errno)))
        }
    }

    private func moveBack(from: String, to: String) throws {
        guard fileManager.fileExists(atPath: from) else {
            throw JournalError.rollbackFailed("目标已不在原处：\(from)")
        }
        try fileManager.moveItem(atPath: from, toPath: to)
    }

    private func load() throws -> JournalFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return JournalFile(version: JournalFile.currentVersion, records: [])
        }
        return try JSONDecoder().decode(JournalFile.self, from: Data(contentsOf: fileURL))
    }

    private func save(_ file: JournalFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
