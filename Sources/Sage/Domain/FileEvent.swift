import Foundation

/// 事件来源：三个 Watcher 产出统一事件（spec §3）。
public enum EventSource: Codable, Sendable, Equatable {
    case folderWatch(root: String)
    case dtWatch(database: String, groupPath: String)
    case manual
}

/// 文件位置：本地路径或 DT 记录。
public enum FileLocation: Codable, Sendable, Equatable, Hashable {
    case local(path: String)
    case devonthink(uuid: String, database: String, groupPath: String)
}

/// 统一文件事件。
public struct FileEvent: Sendable, Equatable {
    public var location: FileLocation
    public var source: EventSource

    public init(location: FileLocation, source: EventSource) {
        self.location = location
        self.source = source
    }

    /// 该事件是否落在给定作用域内。
    public func isCovered(by scope: RuleScope) -> Bool {
        switch (scope, location) {
        case (.manualOnly, _):
            return source == .manual
        case (.localFolder(let root, let recursive), .local(let path)):
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            let rootParts = rootURL.pathComponents
            let fileParts = fileURL.pathComponents
            // 目录组件前缀比较，避免 "/in" 误覆盖 "/inbox"
            guard fileParts.count > rootParts.count,
                  Array(fileParts.prefix(rootParts.count)) == rootParts else { return false }
            if recursive { return true }
            return fileParts.count == rootParts.count + 1
        case (.devonthink(let db, let group), .devonthink(_, let eventDB, let eventGroup)):
            return db == eventDB && group == eventGroup
        default:
            return false
        }
    }
}
