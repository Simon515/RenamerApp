import Foundation

/// 手动拖入/选择 → 一次性批量 FileEvent（source = .manual）。
public struct ManualIntake: Sendable {
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func events(forDroppedPaths paths: [String]) -> [FileEvent] {
        var seen = Set<String>()
        var result: [FileEvent] = []
        for path in paths {
            for filePath in expand(path) where seen.insert(filePath).inserted {
                result.append(FileEvent(location: .local(path: filePath), source: .manual))
            }
        }
        return result
    }

    /// 文件→自身；目录→递归所有非隐藏文件。
    private func expand(_ path: String) -> [String] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return [] }
        if !isDir.boolValue { return [path] }

        var files: [String] = []
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: []) else { return [] }
        for case let url as URL in enumerator {
            let comp = url.lastPathComponent
            if comp.hasPrefix(".") {
                // 跳过隐藏文件/目录（目录则不再深入）
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory { files.append(url.path) }
        }
        return files
    }
}
