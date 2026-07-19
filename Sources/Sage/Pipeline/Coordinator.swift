import Foundation

/// 为 Coordinator 提供当前规则集（每次处理事件时取最新）。
public protocol RulesProviding: Sendable {
    func currentRules() async -> [Rule]
}

/// 编排协调器：事件 → 规则匹配 → 路由（自动执行 / 入确认队列）→ 日志。
public actor Coordinator {
    private let engine: RuleEngine
    private let rulesProvider: any RulesProviding
    private let executor: LocalActionExecutor
    private let journal: Journal
    private let confirmQueue: ConfirmQueue
    private let now: @Sendable () -> Date

    public init(engine: RuleEngine, rulesProvider: any RulesProviding,
                executor: LocalActionExecutor, journal: Journal, confirmQueue: ConfirmQueue,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.rulesProvider = rulesProvider
        self.executor = executor
        self.journal = journal
        self.confirmQueue = confirmQueue
        self.now = now
    }

    public func handle(_ event: FileEvent) async -> [ActionOutcome] {
        let rules = await rulesProvider.currentRules()
        let plan = await engine.plan(for: event, rules: rules)
        guard !plan.planned.isEmpty else { return [.skipped(reason: "无匹配规则")] }

        var outcomes: [ActionOutcome] = []
        for planned in plan.planned {
            if planned.requiresConfirmation {
                let item = PendingItem(id: UUID(), enqueuedAt: now(),
                                       event: FileEventSnapshot(from: event),
                                       planned: PlannedActionsSnapshot(from: planned))
                do {
                    try await confirmQueue.enqueue(item)
                    outcomes.append(.enqueued(item))
                } catch {
                    outcomes.append(.failed(location: planned.location, ruleName: planned.ruleName,
                                            message: error.localizedDescription))
                }
            } else {
                outcomes.append(await execute(planned, includingTrash: false))
            }
        }
        return outcomes
    }

    public func approve(pendingID: UUID) async -> ActionOutcome {
        do {
            guard let item = try await confirmQueue.item(id: pendingID) else {
                return .failed(location: .local(path: ""), ruleName: "",
                               message: "队列中找不到该项。")
            }
            let outcome = await execute(item.planned.plannedActions, includingTrash: true)
            if case .executed = outcome {
                try await confirmQueue.remove(id: pendingID)
            }
            return outcome
        } catch {
            return .failed(location: .local(path: ""), ruleName: "",
                           message: error.localizedDescription)
        }
    }

    public func reject(pendingID: UUID) async throws {
        try await confirmQueue.remove(id: pendingID)
    }

    private func execute(_ planned: PlannedActions, includingTrash: Bool) async -> ActionOutcome {
        do {
            let ops = includingTrash
                ? try await executor.runIncludingTrash(actions: planned.actions, on: planned.location)
                : try await executor.run(actions: planned.actions, on: planned.location)
            let record = JournalRecord(id: UUID(), timestamp: now(), ruleID: planned.ruleID,
                                       ruleName: planned.ruleName,
                                       sourceDescription: describe(planned.location), ops: ops)
            try await journal.append(record)
            return .executed(record)
        } catch let error as PartialActionFailure {
            // 中途失败：已完成的操作必须记入 Journal，否则用户无法查看或回滚。
            let record = JournalRecord(id: UUID(), timestamp: now(), ruleID: planned.ruleID,
                                       ruleName: planned.ruleName,
                                       sourceDescription: describe(planned.location),
                                       ops: error.completedOps)
            try? await journal.append(record)
            return .failed(location: planned.location, ruleName: planned.ruleName,
                           message: error.underlying.localizedDescription)
        } catch {
            return .failed(location: planned.location, ruleName: planned.ruleName,
                           message: error.localizedDescription)
        }
    }

    private func describe(_ location: FileLocation) -> String {
        switch location {
        case .local(let path): return path
        case .devonthink(_, let db, let group): return "DEVONthink:\(db)\(group)"
        }
    }
}
