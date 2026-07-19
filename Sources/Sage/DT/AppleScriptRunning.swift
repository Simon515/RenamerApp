import AppKit
import Foundation

/// AppleScript 字符串字面量转义（顺序关键：先反斜杠）。防注入，spec §5。
public func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

public enum DTError: LocalizedError, Equatable {
    case notRunning
    case scriptFailed(String)
    case needsLocalFile

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "DEVONthink 未运行，相关规则已暂停。"
        case .scriptFailed(let msg): return "DEVONthink 脚本执行失败：\(msg)"
        case .needsLocalFile: return "该 DEVONthink 动作需要本地文件来源。"
        }
    }
}

/// 执行一段 AppleScript 并返回字符串结果。真实实现走 NSAppleScript；测试注入 Fake。
public protocol AppleScriptRunning: Sendable {
    func run(_ source: String) async throws -> String
}

/// NSAppleScript 非线程安全：统一在主线程执行。
public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}
    public func run(_ source: String) async throws -> String {
        try await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                throw DTError.scriptFailed("脚本构造失败")
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知 AppleScript 错误"
                throw DTError.scriptFailed(msg)
            }
            return result.stringValue ?? ""
        }
    }
}

/// DT 是否在运行（DT3 与 DT4 bundle id 均检查）。消费方以 `@Sendable () -> Bool` 注入，测试传假闭包。
public enum DTAvailability {
    public static func isRunning() -> Bool {
        let ids = ["com.devon-technologies.think3", "com.devon-technologies.think"]
        return ids.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }
}
