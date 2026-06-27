import Foundation

enum CopyOrMove: String, Codable, CaseIterable, Sendable {
    case copy, move
}

enum ExportTarget: Codable, Sendable, Equatable {
    case devonthink(database: String, group: String)
}

enum AnalysisError: LocalizedError, Sendable {
    case unreadable(URL)
    case unsupportedType(String)
    case cloudDecodingFailed
    case cloudHTTPStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "无法读取：\(url.path())"
        case .unsupportedType(let detail):
            return detail
        case .cloudDecodingFailed:
            return "云端响应解析失败"
        case .cloudHTTPStatus(let status):
            return "云端请求失败（HTTP \(status)）"
        }
    }
}
