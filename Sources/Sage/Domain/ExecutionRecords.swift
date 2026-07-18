import Foundation

/// 一步可逆的文件系统变更；回滚时逆序反做。
public enum ReversibleOp: Codable, Sendable, Equatable {
    case moved(from: String, to: String)
    case copied(to: String)
    case renamed(from: String, to: String)
    case trashed(originalPath: String, trashPath: String?)
    case addedFinderTags([String], to: String, previous: [String])
}

/// 一次成功执行的操作记录（用于日志展示与回滚）。
public struct JournalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var ruleID: UUID
    public var ruleName: String
    public var sourceDescription: String
    public var ops: [ReversibleOp]

    public init(id: UUID, timestamp: Date, ruleID: UUID, ruleName: String,
                sourceDescription: String, ops: [ReversibleOp]) {
        self.id = id; self.timestamp = timestamp; self.ruleID = ruleID
        self.ruleName = ruleName; self.sourceDescription = sourceDescription; self.ops = ops
    }
}

/// FileEvent 的可持久化快照（FileEvent 本身未声明 Codable，不改动已审查的 Domain 文件）。
public struct FileEventSnapshot: Codable, Sendable, Equatable {
    public var location: FileLocation
    public var source: EventSource

    public init(location: FileLocation, source: EventSource) {
        self.location = location; self.source = source
    }
    public init(from event: FileEvent) { self.init(location: event.location, source: event.source) }
    public var fileEvent: FileEvent { FileEvent(location: location, source: source) }
}

/// PlannedActions 的可持久化快照。
public struct PlannedActionsSnapshot: Codable, Sendable, Equatable {
    public var ruleID: UUID
    public var ruleName: String
    public var location: FileLocation
    public var actions: [Action]
    public var requiresConfirmation: Bool

    public init(ruleID: UUID, ruleName: String, location: FileLocation,
                actions: [Action], requiresConfirmation: Bool) {
        self.ruleID = ruleID; self.ruleName = ruleName; self.location = location
        self.actions = actions; self.requiresConfirmation = requiresConfirmation
    }
    public init(from p: PlannedActions) {
        self.init(ruleID: p.ruleID, ruleName: p.ruleName, location: p.location,
                  actions: p.actions, requiresConfirmation: p.requiresConfirmation)
    }
    public var plannedActions: PlannedActions {
        PlannedActions(ruleID: ruleID, ruleName: ruleName, location: location,
                       actions: actions, requiresConfirmation: requiresConfirmation)
    }
}

/// 待确认队列中的一项。
public struct PendingItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enqueuedAt: Date
    public var event: FileEventSnapshot
    public var planned: PlannedActionsSnapshot

    public init(id: UUID, enqueuedAt: Date, event: FileEventSnapshot, planned: PlannedActionsSnapshot) {
        self.id = id; self.enqueuedAt = enqueuedAt; self.event = event; self.planned = planned
    }
}

/// 单条 PlannedActions 处理后的结果。
public enum ActionOutcome: Sendable, Equatable {
    case executed(JournalRecord)
    case enqueued(PendingItem)
    case failed(location: FileLocation, ruleName: String, message: String)
    case skipped(reason: String)
}
