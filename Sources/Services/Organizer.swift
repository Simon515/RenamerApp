import Foundation

actor Organizer {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager = PluginManager()) {
        self.pluginManager = pluginManager
    }

    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove = .copy) async throws -> FileOperationRecord {
        var moves: [FileOperationRecord.Move] = []
        var exports: [FileOperationRecord.Export] = []
        let fm = FileManager.default

        for op in plan.operations where op.isEnabled {
            let destDir = op.destination.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            switch operation {
            case .copy:
                try fm.copyItem(at: op.source, to: op.destination)
            case .move:
                try fm.moveItem(at: op.source, to: op.destination)
            }
            moves.append(FileOperationRecord.Move(source: op.source, destination: op.destination, operation: operation))

            for target in op.exportTargets {
                do {
                    let exportRecord = try await pluginManager.export(file: op.destination, target: target)
                    exports.append(exportRecord)
                } catch {
                    let pluginID = await pluginManager.pluginID(for: target) ?? "unknown"
                    exports.append(FileOperationRecord.Export(pluginID: pluginID, details: error.localizedDescription))
                }
            }
        }

        return FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
    }
}
