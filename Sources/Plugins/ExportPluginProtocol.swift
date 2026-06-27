import Foundation

protocol ExportPlugin: Sendable {
    var id: String { get }
    var name: String { get }
    func canHandle(target: ExportTarget) -> Bool
    func export(file: URL, target: ExportTarget) async throws -> String
}
