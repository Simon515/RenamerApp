import Foundation

/// 为 LLM 命名动作提供文件元数据。
public protocol MetadataProviding: Sendable {
    func metadata(for location: FileLocation) async throws -> ExtractedMetadata
}

/// DEVONthink 动作执行留座（真实实现在第 5 份计划）。
public protocol DTActionExecutor: Sendable {
    func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp]
}

public enum ActionExecutionError: LocalizedError {
    case notLocalFile
    case unsupportedAction(String)
    case sourceMissing(String)
    case finderTagsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLocalFile: return "该动作只能作用于本地文件。"
        case .unsupportedAction(let name): return "动作「\(name)」在当前版本尚未支持执行。"
        case .sourceMissing(let path): return "源文件不存在：\(path)"
        case .finderTagsFailed(let msg): return "写入 Finder 标签失败：\(msg)"
        }
    }
}

/// DEVONthink 动作在本计划未实现，一律抛错（第 5 份计划替换）。
public struct UnimplementedDTActionExecutor: DTActionExecutor {
    public init() {}
    public func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp] {
        throw ActionExecutionError.unsupportedAction("DEVONthink 动作")
    }
}
