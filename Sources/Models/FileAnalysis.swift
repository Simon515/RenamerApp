import Foundation

struct FileAnalysis: Sendable, Identifiable {
    let id: UUID
    var title: String?
    var date: Date?
    var category: String?
    var tags: [String]
    var source: String?
    var summary: String?
    var confidence: Double
}
