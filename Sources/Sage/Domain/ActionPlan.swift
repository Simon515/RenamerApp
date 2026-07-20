import Foundation

/// 单条规则命中后待执行的动作集。
public struct PlannedActions: Sendable, Equatable {
    public var ruleID: UUID
    public var ruleName: String
    public var location: FileLocation
    public var actions: [Action]
    public var requiresConfirmation: Bool

    public init(ruleID: UUID, ruleName: String, location: FileLocation,
                actions: [Action], requiresConfirmation: Bool) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.location = location
        self.actions = actions
        self.requiresConfirmation = requiresConfirmation
    }
}

/// 一次事件的完整执行计划。
public struct ActionPlan: Sendable, Equatable {
    public var event: FileEvent
    public var planned: [PlannedActions]

    public init(event: FileEvent, planned: [PlannedActions]) {
        self.event = event
        self.planned = planned
    }
}
