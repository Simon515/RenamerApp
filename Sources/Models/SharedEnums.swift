import Foundation

enum CopyOrMove: String, Codable, CaseIterable, Sendable {
    case copy, move
}

enum ExportTarget: Codable, Sendable, Equatable {
    case devonthink(database: String, group: String)
}

enum AnalysisError: Error, Sendable {
    case unreadable(URL)
    case unsupportedType(String)
    case cloudDecodingFailed
    case cloudHTTPStatus(Int)
}
