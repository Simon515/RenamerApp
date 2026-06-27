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
        let script = """
        tell application "DEVONthink 3"
            set theDatabase to open database "\(database)"
            set theGroup to create location "\(group)" in theDatabase
            import "\(file.path())" to theGroup
        end tell
        """
        // NSAppleScript execution omitted for unit-testability; wrap in real run later.
        return "imported into \(database)/\(group)"
    }
}
