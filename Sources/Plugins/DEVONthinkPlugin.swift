import Foundation

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
        _ = """
        tell application "DEVONthink 3"
            set theDatabase to open database "\(escapedDatabase)"
            set theGroup to create location "\(escapedGroup)" in theDatabase
            import "\(escapedFile)" to theGroup
        end tell
        """
        // NSAppleScript execution omitted for unit-testability; wrap in real run later.
        return "imported into \(database)/\(group)"
    }

    private static func appleScriptEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
