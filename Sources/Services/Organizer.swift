import Foundation

actor Organizer {
    func execute(plan: OrganizationPlan, taskName: String) async throws -> FileOperationRecord {
        var moves: [FileOperationRecord.Move] = []
        let fm = FileManager.default

        for op in plan.operations where op.isEnabled {
            let destDir = op.destination.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(at: op.source, to: op.destination)
            moves.append(FileOperationRecord.Move(source: op.source, destination: op.destination))
        }

        return FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: [])
    }
}
