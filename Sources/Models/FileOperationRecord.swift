import Foundation

struct FileOperationRecord: Codable, Identifiable, Sendable {
    struct Move: Codable, Sendable {
        let source: URL
        let destination: URL
    }
    struct Export: Codable, Sendable {
        let pluginID: String
        let details: String
    }

    let id: UUID
    let timestamp: Date
    let taskName: String
    let moves: [Move]
    let exports: [Export]
}
