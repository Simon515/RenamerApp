import Foundation

/// 条件求值成本档次：引擎按档次从低到高求值，档次内条件全部通过才进入下一档。
public enum CostTier: Int, Codable, Sendable, Comparable {
    case free = 0        // 文件属性，零成本
    case extraction = 1  // 需要内容提取（文本/哈希/EXIF）
    case llm = 2         // 需要 LLM 调用

    public static func < (lhs: CostTier, rhs: CostTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 规则条件全集（spec §4）。
public enum Condition: Codable, Sendable, Equatable {
    // 零成本
    case name(StringMatch)
    case fileExtension(StringMatch)
    case sizeBytes(min: Int64?, max: Int64?)
    case createdWithinDays(Int)
    case modifiedWithinDays(Int)
    case utTypeConforms(String)
    // 内容提取
    case textContent(StringMatch)
    case isDuplicate
    case captureDateWithinDays(Int)
    case sourceURL(StringMatch)
    // LLM
    case contentBelongsTo(category: String, minConfidence: Double)
    case contentMatchesDescription(String)

    public var tier: CostTier {
        switch self {
        case .name, .fileExtension, .sizeBytes, .createdWithinDays,
             .modifiedWithinDays, .utTypeConforms:
            return .free
        case .textContent, .isDuplicate, .captureDateWithinDays, .sourceURL:
            return .extraction
        case .contentBelongsTo, .contentMatchesDescription:
            return .llm
        }
    }
}
