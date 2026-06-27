import Foundation

struct OrganizationTask: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var sourceFolders: [URL]
    var templateID: UUID
    var destinationFolder: URL
    var operation: CopyOrMove
    var exportTargets: [ExportTarget]
    var useCloudAI: Bool
}
