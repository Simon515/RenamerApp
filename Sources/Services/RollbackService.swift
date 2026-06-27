import Foundation

/// 批量回滚过程中单个操作失败的错误。
struct RollbackMoveError: Error, Sendable {
    let source: URL
    let destination: URL
    let underlying: Error
}

/// 回滚多个操作时出现部分失败时抛出的聚合错误。
struct RollbackAggregateError: Error, Sendable {
    let errors: [RollbackMoveError]

    var localizedDescription: String {
        "回滚部分失败（\(errors.count) 项）：" + errors.map { $0.underlying.localizedDescription }.joined(separator: "; ")
    }
}

actor RollbackService {
    private let recordsURL: URL

    init(recordsURL: URL? = nil) {
        self.recordsURL = recordsURL ?? RollbackService.defaultRecordsURL()
    }

    private static func defaultRecordsURL() -> URL {
        guard let supportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("com.renamer.records", isDirectory: true)
        }
        return supportURL.appendingPathComponent("com.renamer.records", isDirectory: true)
    }

    func save(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        let url = recordsURL.appending(path: "\(record.id.uuidString).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url)

        // 只保留最近 50 条记录，防止磁盘无限增长。
        await pruneRecords(keeping: 50)
    }

    func rollback(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        var failures: [RollbackMoveError] = []

        for move in record.moves {
            do {
                switch move.operation {
                case .move:
                    // 若源文件已被覆盖或不存在，则尝试创建中间目录后移动。
                    let destDir = move.source.deletingLastPathComponent()
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    try fm.moveItem(at: move.destination, to: move.source)
                case .copy:
                    try fm.removeItem(at: move.destination)
                }
            } catch {
                failures.append(RollbackMoveError(source: move.source, destination: move.destination, underlying: error))
            }
        }

        if !failures.isEmpty {
            throw RollbackAggregateError(errors: failures)
        }
    }

    /// 删除旧记录文件，仅保留最近的 `count` 条。
    private func pruneRecords(keeping count: Int) async {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let dated = urls.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }
        .sorted { $0.date > $1.date }

        guard dated.count > count else { return }

        for entry in dated.dropFirst(count) {
            try? fm.removeItem(at: entry.url)
        }
    }
}
