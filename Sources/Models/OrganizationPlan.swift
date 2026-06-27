import Foundation

struct OrganizationPlan: Sendable, Identifiable {
    let id: UUID
    let taskID: UUID?
    let analyses: [FileAnalysis]
    var operations: [PlanOperation]
    let duplicateGroups: [DuplicateGroup]
    var operation: CopyOrMove
}
