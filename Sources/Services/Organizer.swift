import Foundation

/// 整理过程中发生的错误，携带已完成的操作记录以支持部分回滚。
struct OrganizerError: Error, Sendable {
    let partialRecord: FileOperationRecord
    let underlying: Error

    var localizedDescription: String {
        "整理未完成：\(underlying.localizedDescription)（已完成 \(partialRecord.moves.count) 项）"
    }
}

actor Organizer {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager = PluginManager()) {
        self.pluginManager = pluginManager
    }

    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove = .copy) async throws -> FileOperationRecord {
        var moves: [FileOperationRecord.Move] = []
        var exports: [FileOperationRecord.Export] = []
        let fm = FileManager.default

        do {
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
        } catch {
            let partialRecord = FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
            throw OrganizerError(partialRecord: partialRecord, underlying: error)
        }

        return FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
    }
}
