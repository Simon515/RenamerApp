/// 规则适用范围。
public enum RuleScope: Codable, Sendable, Equatable {
    case localFolder(path: String, recursive: Bool)
    case devonthink(database: String, groupPath: String)
    case manualOnly
}

/// 触发方式。
public enum TriggerMode: String, Codable, Sendable {
    case automatic   // 监控自动
    case manualOnly  // 仅手动
}

/// 条件组合逻辑（单层，spec 明确不做嵌套组）。
public enum ConditionLogic: String, Codable, Sendable {
    case all
    case any
}

/// 执行模式。
public enum ExecutionMode: String, Codable, Sendable {
    case automatic     // 自动执行
    case confirmFirst  // 先入确认队列
}
