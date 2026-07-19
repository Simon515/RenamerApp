import Foundation

public struct ConfirmQueueFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var items: [PendingItem]
    public init(version: Int, items: [PendingItem]) { self.version = version; self.items = items }
}

/// 待确认队列（actor：串行读写）。
public actor ConfirmQueue {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("confirm-queue.json")
        self.fileManager = fileManager
    }

    public func enqueue(_ item: PendingItem) throws {
        var file = try load()
        file.items.append(item)
        try save(file)
    }

    public func all() throws -> [PendingItem] {
        try load().items.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    public func item(id: UUID) throws -> PendingItem? {
        try load().items.first { $0.id == id }
    }

    public func remove(id: UUID) throws {
        var file = try load()
        file.items.removeAll { $0.id == id }
        try save(file)
    }

    public func count() throws -> Int { try load().items.count }

    private func load() throws -> ConfirmQueueFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ConfirmQueueFile(version: ConfirmQueueFile.currentVersion, items: [])
        }
        return try JSONDecoder().decode(ConfirmQueueFile.self, from: Data(contentsOf: fileURL))
    }

    private func save(_ file: ConfirmQueueFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
