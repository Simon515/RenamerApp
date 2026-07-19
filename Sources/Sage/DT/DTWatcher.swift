import Foundation

public struct DTWatchedGroup: Sendable, Equatable, Hashable {
    public let database: String
    public let groupPath: String
    public init(database: String, groupPath: String) {
        self.database = database; self.groupPath = groupPath
    }
}

/// DT 组轮询监控（spec §5）：以「已见 uuid → 修改时间 token」识别新/变条目。
/// DT 未运行：跳过轮询、回调可用性变化、不弹错误；恢复后自动续（spec §5/§8）。
public actor DTWatcher {
    private let groups: [DTWatchedGroup]
    private let runner: any AppleScriptRunning
    private let pollInterval: Duration
    private let isRunning: @Sendable () -> Bool
    private let onEvent: @Sendable (FileEvent) async -> Void
    private let onAvailabilityChange: (@Sendable (Bool) async -> Void)?

    private var seen: [DTWatchedGroup: [String: String]] = [:]  // group → uuid → modToken
    private var baselineBuilt: Set<DTWatchedGroup> = []
    private var lastAvailability: Bool?
    private var loopTask: Task<Void, Never>?

    public init(groups: [DTWatchedGroup], runner: any AppleScriptRunning = NSAppleScriptRunner(),
                pollInterval: Duration = .seconds(60),
                isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning,
                onEvent: @escaping @Sendable (FileEvent) async -> Void,
                onAvailabilityChange: (@Sendable (Bool) async -> Void)? = nil) {
        self.groups = groups
        self.runner = runner
        self.pollInterval = pollInterval
        self.isRunning = isRunning
        self.onEvent = onEvent
        self.onAvailabilityChange = onAvailabilityChange
    }

    /// 启用+自动触发规则声明的 DT 作用域，去重（与 WatcherSupervisor.watchedRoots 同构）。
    public nonisolated static func watchedGroups(rules: [Rule]) -> [DTWatchedGroup] {
        var out: [DTWatchedGroup] = []
        for rule in rules where rule.enabled && rule.trigger == .automatic {
            for scope in rule.scopes {
                if case .devonthink(let db, let group) = scope {
                    let g = DTWatchedGroup(database: db, groupPath: group)
                    if !out.contains(g) { out.append(g) }
                }
            }
        }
        return out
    }

    /// 启动轮询循环（幂等：已启动则忽略）。
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [pollInterval] in
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 单轮轮询（拆出供测试直接调用，不起循环）。
    public func pollOnce() async {
        let available = isRunning()
        if available != lastAvailability {
            lastAvailability = available
            await onAvailabilityChange?(available)
        }
        guard available else { return }

        for group in groups {
            let raw: String
            do {
                raw = try await runner.run(DTScriptBuilder.listGroupScript(
                    database: group.database, groupPath: group.groupPath))
            } catch {
                NSLog("DTWatcher 轮询失败（\(group.database)\(group.groupPath)）：\(error.localizedDescription)")
                continue
            }

            var current: [String: String] = [:]
            for line in raw.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                current[parts[0]] = parts[1]
            }

            defer { seen[group] = current }
            guard baselineBuilt.contains(group) else {
                baselineBuilt.insert(group)   // 首轮只建基线，不发事件（与 FolderWatcher 语义一致）
                continue
            }
            let previous = seen[group] ?? [:]
            for (uuid, token) in current where previous[uuid] != token {
                await onEvent(FileEvent(
                    location: .devonthink(uuid: uuid, database: group.database, groupPath: group.groupPath),
                    source: .dtWatch(database: group.database, groupPath: group.groupPath)))
            }
        }
    }
}
