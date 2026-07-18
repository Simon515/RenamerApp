import Foundation

/// 规则：Sage 的核心配置单元（spec §4）。
public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var scopes: [RuleScope]
    public var trigger: TriggerMode
    public var conditionLogic: ConditionLogic
    public var conditions: [Condition]
    public var actions: [Action]
    public var executionMode: ExecutionMode

    public init(id: UUID, name: String, enabled: Bool, scopes: [RuleScope],
                trigger: TriggerMode, conditionLogic: ConditionLogic,
                conditions: [Condition], actions: [Action], executionMode: ExecutionMode) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.scopes = scopes
        self.trigger = trigger
        self.conditionLogic = conditionLogic
        self.conditions = conditions
        self.actions = actions
        self.executionMode = executionMode
    }

    /// 条件或动作是否用到 LLM（UI 中显示 ✦ 标记的依据）。
    public var usesLLM: Bool {
        conditions.contains { $0.tier == .llm } || actions.contains { $0.usesLLM }
    }

    /// 是否必须走确认队列：显式设置，或含删除类动作（spec §7.1 强制）。
    public var requiresConfirmation: Bool {
        executionMode == .confirmFirst || actions.contains(.moveToTrash)
    }
}
