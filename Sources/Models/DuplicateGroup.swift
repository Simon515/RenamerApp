import Foundation

struct DuplicateGroup: Sendable, Identifiable {
    let id: UUID
    let hash: String
    let items: [FileItem]
    var keepIndex: Int?
}
