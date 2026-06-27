import Foundation
import Cocoa

struct DEVONthinkPlugin: ExportPlugin {
    let id = "devonthink"
    let name = "DEVONthink"

    func canHandle(target: ExportTarget) -> Bool {
        if case .devonthink = target { return true }
        return false
    }

    func export(file: URL, target: ExportTarget) async throws -> String {
        guard case .devonthink(let database, let group) = target else {
            throw AnalysisError.unsupportedType("target")
        }
        let escapedDatabase = Self.appleScriptEscape(database)
        let escapedGroup = Self.appleScriptEscape(group)
        let escapedFile = Self.appleScriptEscape(file.path())
        let scriptSource = """
        tell application "DEVONthink 3"
            set theDatabase to open database "\(escapedDatabase)"
            set theGroup to create location "\(escapedGroup)" in theDatabase
            import "\(escapedFile)" to theGroup
        end tell
        """

        guard let appleScript = NSAppleScript(source: scriptSource) else {
            throw AnalysisError.unsupportedType("无法创建 AppleScript")
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知 AppleScript 错误"
            throw AnalysisError.unsupportedType("DEVONthink 导出失败：\(message)")
        }

        return "imported into \(database)/\(group)"
    }

    private static func appleScriptEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
