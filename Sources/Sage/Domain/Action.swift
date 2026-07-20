/// 规则动作全集（spec §4）。执行语义在第 3/5 份计划（Execution 层）实现。
public enum Action: Codable, Sendable, Equatable {
    // 本地文件
    case moveTo(path: String)
    case copyTo(path: String)
    case rename(template: String)
    case addFinderTags([String])
    case moveToTrash
    // DEVONthink
    case dtImport(database: String, groupPath: String, tags: [String], noteTemplate: String?)
    case dtRename(template: String)
    case dtAddTags([String])
    case dtMoveToGroup(database: String, groupPath: String)
    // LLM
    case llmExtractMetadata
    case llmRename(instruction: String)
    // 控制
    case continueMatching

    /// 该动作是否需要 LLM 参与。
    public var usesLLM: Bool {
        switch self {
        case .llmExtractMetadata, .llmRename: return true
        default: return false
        }
    }
}
