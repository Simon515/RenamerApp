import Foundation

struct OrganizationPlan: Sendable, Identifiable {
    let id: UUID
    let taskID: UUID?
    let analyses: [FileAnalysis]
    let operations: [PlanOperation]
    let duplicateGroups: [DuplicateGroup]
}
