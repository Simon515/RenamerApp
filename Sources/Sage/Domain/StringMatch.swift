import Foundation

/// 字符串匹配方式：规则条件中所有文本类比较的统一表达。
public enum StringMatch: Codable, Sendable, Equatable {
    case equals(String)      // 忽略大小写的相等
    case contains(String)    // 忽略大小写的包含
    case regex(String)       // 正则（区分大小写，由用户模式自行控制）

    public func matches(_ value: String) -> Bool {
        switch self {
        case .equals(let target):
            return value.caseInsensitiveCompare(target) == .orderedSame
        case .contains(let target):
            return value.range(of: target, options: .caseInsensitive) != nil
        case .regex(let pattern):
            // 非法正则视为不匹配，不抛错——规则求值不应因用户输入中断
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, range: range) != nil
        }
    }
}
