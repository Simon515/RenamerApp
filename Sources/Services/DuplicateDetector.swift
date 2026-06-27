import Foundation
import CryptoKit

/// 重复文件检测结果。
struct DuplicateDetectionResult: Sendable {
    let groups: [DuplicateGroup]
    let inaccessibleCount: Int
}

/// 通过文件内容 SHA-256 哈希检测重复文件。
actor DuplicateDetector {
    /// 在传入的文件列表中检测内容完全相同的文件。
    /// - Parameter items: 待检测的 `FileItem` 数组。
    /// - Returns: 重复文件组以及无法读取的文件数量；单个文件读取失败不会中断整个批次。
    func detectDuplicates(in items: [FileItem]) async -> DuplicateDetectionResult {
        // 使用 (hash, [(index, FileItem)]) 保留原始输入顺序，避免并发完成顺序影响重复组内排序。
        var groups: [String: [(Int, FileItem)]] = [:]
        var inaccessibleCount = 0

        // 限制并发哈希任务数量，避免大目录下同时打开过多文件描述符。
        let maxConcurrent = min(16, max(4, ProcessInfo.processInfo.processorCount))

        await withTaskGroup(of: (Int, FileItem, Result<String, Error>).self) { group in
            var iterator = items.enumerated().makeIterator()
            var running = 0

            func launchNext() {
                guard running < maxConcurrent, let (index, item) = iterator.next() else { return }
                group.addTask { [self] in
                    let result = Result { try self.hashFile(at: item.url) }
                    return (index, item, result)
                }
                running += 1
            }

            // 启动初始批次。
            while running < maxConcurrent { launchNext() }

            // 每完成一个任务就补充一个新的，保持并发度恒定。
            for await (index, item, result) in group {
                running -= 1
                switch result {
                case .success(let hash):
                    groups[hash, default: []].append((index, item))
                case .failure:
                    inaccessibleCount += 1
                }
                launchNext()
            }
        }

        let duplicateGroups = groups
            .filter { $0.value.count > 1 }
            .map { hash, pairs in
                let sortedItems = pairs.sorted { $0.0 < $1.0 }.map { $0.1 }
                return DuplicateGroup(id: UUID(), hash: hash, items: sortedItems, keepIndex: 0)
            }
            .sorted { $0.hash < $1.hash }
        return DuplicateDetectionResult(groups: duplicateGroups, inaccessibleCount: inaccessibleCount)
    }

    /// 计算指定文件的 SHA-256 哈希值。
    /// - Parameter url: 待哈希文件的本地 URL。
    /// - Returns: 文件内容的十六进制哈希字符串。
    private nonisolated func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
