import Foundation

struct NamingTemplate: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var folderTemplate: String
    var fileNameTemplate: String
}
