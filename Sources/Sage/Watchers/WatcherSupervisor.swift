import Foundation

/// 需监控的本地根目录。
public struct WatchedRoot: Sendable, Equatable, Hashable {
    public let path: String
    public let recursive: Bool
    public init(path: String, recursive: Bool) { self.path = path; self.recursive = recursive }
}

/// 监控总管：按当前规则集启停 FolderWatcher 与 DTWatcher，事件转交 Coordinator。
public actor WatcherSupervisor {
    private let coordinator: Coordinator
    private var watchers: [FolderWatcher] = []

    private let dtRunner: any AppleScriptRunning
    private let dtIsRunning: @Sendable () -> Bool
    private var dtAvailabilityHandler: (@Sendable (Bool) async -> Void)?
    private var dtWatcher: DTWatcher?

    public init(coordinator: Coordinator,
                dtRunner: any AppleScriptRunning = NSAppleScriptRunner(),
                dtIsRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning) {
        self.coordinator = coordinator
        self.dtRunner = dtRunner
        self.dtIsRunning = dtIsRunning
    }

    /// DT 可用性变化回调（菜单栏提示用）。构造后注入，避免 AppModel init 循环引用。
    public func setDTAvailabilityHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
        dtAvailabilityHandler = handler
    }

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

        let dtGroups = DTWatcher.watchedGroups(rules: rules)
        if !dtGroups.isEmpty {
            let handler = dtAvailabilityHandler
            let watcher = DTWatcher(groups: dtGroups, runner: dtRunner,
                                    isRunning: dtIsRunning,
                                    onEvent: { event in _ = await coordinator.handle(event) },
                                    onAvailabilityChange: handler)
            await watcher.start()
            dtWatcher = watcher
        }
    }

    public func stopAll() async {
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
        await dtWatcher?.stop()
        dtWatcher = nil
    }

    public func restart(rules: [Rule]) async {
        await stopAll()
        await start(rules: rules)
    }
}
