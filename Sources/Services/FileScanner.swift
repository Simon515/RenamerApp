import Foundation
import UniformTypeIdentifiers

/// 递归并发文件扫描器。
///
/// 对多个输入目录并行执行扫描，返回扁平化的 `FileItem` 列表。
/// 扫描时会跳过隐藏文件、包后代、非普通文件（如目录、符号链接等）以及常见系统目录。
actor FileScanner {
    /// 扫描时应跳过的系统目录名列表。
    private static let skippedSystemDirectories: Set<String> = [
        ".Trash", ".fseventsd", ".Spotlight-V100", "TemporaryItems",
        ".DS_Store", ".DocumentRevisions-V100", ".PKInstallSandboxManager-SystemSoftware"
    ]
    /// 并发扫描多个文件夹。
    /// - Parameter folders: 待扫描的目录 URL 列表。
    /// - Returns: 所有扫描到的文件模型列表。
    func scan(folders: [URL]) async throws -> [FileItem] {
        try await withThrowingTaskGroup(of: [FileItem].self) { group in
            for folder in folders {
                group.addTask { try await self.scan(folder: folder) }
            }
            var all: [FileItem] = []
            for try await items in group {
                all.append(contentsOf: items)
            }
            return all
        }
    }

    /// 递归扫描单个文件夹。
    /// - Parameter folder: 待扫描的目录 URL。
    /// - Returns: 该目录下扫描到的文件模型列表。
    private func scan(folder: URL) async throws -> [FileItem] {
        try scanSynchronously(folder: folder)
    }

    /// 同步执行文件枚举，避免 `DirectoryEnumerator` 在异步上下文中调用迭代器。
    /// - Parameter folder: 待扫描的目录 URL。
    /// - Returns: 该目录下扫描到的文件模型列表。
    private nonisolated func scanSynchronously(folder: URL) throws -> [FileItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AnalysisError.unreadable(folder)
        }

        var items: [FileItem] = []
        for case let url as URL in enumerator {
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey]
            let attrs = try? url.resourceValues(forKeys: resourceKeys)

            if attrs?.isDirectory == true {
                if Self.skippedSystemDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard attrs?.isRegularFile == true else { continue }

            items.append(FileItem(
                id: UUID(),
                url: url,
                name: url.lastPathComponent,
                pathExtension: url.pathExtension,
                size: Int64(attrs?.fileSize ?? 0),
                creationDate: attrs?.creationDate,
                modificationDate: attrs?.contentModificationDate,
                contentType: attrs?.contentType
            ))
        }
        return items
    }
}
