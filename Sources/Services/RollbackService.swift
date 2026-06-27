import Foundation

/// 批量回滚过程中单个操作失败的错误。
struct RollbackMoveError: Error, Sendable {
    let source: URL
    let destination: URL
    let underlying: Error
}

/// 回滚时源路径已存在，目标被移动到冲突路径的记录。
struct RollbackConflict: Sendable {
    let expectedSource: URL
    let destination: URL
    let resolvedAt: URL
}

/// 回滚多个操作时出现部分失败或冲突时抛出的聚合错误。
struct RollbackAggregateError: Error, Sendable {
    let errors: [RollbackMoveError]
    let conflicts: [RollbackConflict]

    var localizedDescription: String {
        var parts: [String] = []
        if !errors.isEmpty {
            parts.append("回滚部分失败（\(errors.count) 项）：" + errors.map { $0.underlying.localizedDescription }.joined(separator: "; "))
        }
        if !conflicts.isEmpty {
            let descriptions = conflicts.map {
                "源路径 \($0.expectedSource.path()) 已存在，已将文件移至 \($0.resolvedAt.path())"
            }
            parts.append("回滚冲突（\(conflicts.count) 项）：" + descriptions.joined(separator: "; "))
        }
        return parts.isEmpty ? "未知回滚错误" : parts.joined(separator: "\n")
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
        var conflicts: [RollbackConflict] = []

        for move in record.moves {
            do {
                switch move.operation {
                case .move:
                    // 若源文件已被覆盖或不存在，则尝试创建中间目录后移动。
                    let destDir = move.source.deletingLastPathComponent()
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: move.source.path()) {
                        let resolvedURL = makeConflictURL(for: move.source, fm: fm)
                        try fm.moveItem(at: move.destination, to: resolvedURL)
                        conflicts.append(RollbackConflict(expectedSource: move.source, destination: move.destination, resolvedAt: resolvedURL))
                    } else {
                        try fm.moveItem(at: move.destination, to: move.source)
                    }
                case .copy:
                    try fm.removeItem(at: move.destination)
                }
            } catch {
                failures.append(RollbackMoveError(source: move.source, destination: move.destination, underlying: error))
            }
        }

        if !failures.isEmpty || !conflicts.isEmpty {
            throw RollbackAggregateError(errors: failures, conflicts: conflicts)
        }
    }

    /// 当源路径已存在时，生成一个相邻的冲突路径（如 `file_restored.txt` 或 `file_restored_01.txt`）。
    private func makeConflictURL(for source: URL, fm: FileManager) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let candidate = dir.appending(path: ext.isEmpty ? "\(base)_restored" : "\(base)_restored.\(ext)")
        if !fm.fileExists(atPath: candidate.path()) {
            return candidate
        }
        var counter = 1
        while true {
            let suffix = String(format: "%02d", counter)
            let numbered = dir.appending(path: ext.isEmpty ? "\(base)_restored_\(suffix)" : "\(base)_restored_\(suffix).\(ext)")
            if !fm.fileExists(atPath: numbered.path()) {
                return numbered
            }
            counter += 1
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
