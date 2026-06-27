import Foundation

struct PlanOperation: Identifiable, Sendable {
    let id: UUID
    let source: URL
    let analysisID: UUID
    var destination: URL
    let exportTargets: [ExportTarget]
    var isEnabled: Bool
}
