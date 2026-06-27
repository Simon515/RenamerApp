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
        var groups: [String: [FileItem]] = [:]
        var inaccessibleCount = 0
        for item in items {
            do {
                let hash = try hashFile(at: item.url)
                groups[hash, default: []].append(item)
            } catch {
                inaccessibleCount += 1
            }
        }
        let duplicateGroups = groups
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: UUID(), hash: $0.key, items: $0.value, keepIndex: 0) }
            .sorted { $0.hash < $1.hash }
        return DuplicateDetectionResult(groups: duplicateGroups, inaccessibleCount: inaccessibleCount)
    }

    /// 计算指定文件的 SHA-256 哈希值。
    /// - Parameter url: 待哈希文件的本地 URL。
    /// - Returns: 文件内容的十六进制哈希字符串。
    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
