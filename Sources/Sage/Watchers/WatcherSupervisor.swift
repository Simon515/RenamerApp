import Foundation

/// 需监控的本地根目录。
public struct WatchedRoot: Sendable, Equatable, Hashable {
    public let path: String
    public let recursive: Bool
    public init(path: String, recursive: Bool) { self.path = path; self.recursive = recursive }
}

/// 监控总管：按当前规则集启停 FolderWatcher，事件转交 Coordinator。
public actor WatcherSupervisor {
    private let coordinator: Coordinator
    private var watchers: [FolderWatcher] = []

    public init(coordinator: Coordinator) { self.coordinator = coordinator }

    /// 从启用的自动规则收集去重监控根（同 path 有递归则合并为递归）。
    public nonisolated static func watchedRoots(rules: [Rule]) -> [WatchedRoot] {
        var map: [String: Bool] = [:] // path -> recursive
        for rule in rules where rule.enabled && rule.trigger == .automatic {
            for scope in rule.scopes {
                if case .localFolder(let path, let recursive) = scope {
                    map[path] = (map[path] ?? false) || recursive
                }
            }
        }
        return map.map { WatchedRoot(path: $0.key, recursive: $0.value) }
    }

    public func start(rules: [Rule]) async {
        let roots = Self.watchedRoots(rules: rules)
        let coordinator = self.coordinator
        for root in roots {
            let watcher = FolderWatcher(roots: [root.path], recursive: root.recursive) { event in
                _ = await coordinator.handle(event)
            }
            watcher.start()
            watchers.append(watcher)
        }
    }

    public func stopAll() async {
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
    }

    public func restart(rules: [Rule]) async {
        await stopAll()
        await start(rules: rules)
    }
}
