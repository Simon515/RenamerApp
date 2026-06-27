import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let pathExtension: String
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let contentType: UTType?
}
