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
        var skippedCount = 0
        let fm = FileManager.default

        do {
            for op in plan.operations where op.isEnabled {
                let destDir = op.destination.deletingLastPathComponent()
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // 如果目标已存在，跳过并记录，避免整批失败。
                if fm.fileExists(atPath: op.destination.path()) {
                    skippedCount += 1
                    continue
                }

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

        let record = FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
        if skippedCount > 0 {
            throw OrganizerError(partialRecord: record, underlying: OrganizerSkippedError(skippedCount: skippedCount))
        }
        return record
    }
}

/// 表示部分操作被跳过（如目标文件已存在）的错误，用于向用户展示非致命警告。
struct OrganizerSkippedError: Error, Sendable {
    let skippedCount: Int

    var localizedDescription: String {
        "\(skippedCount) 个目标文件已存在，已自动跳过"
    }
}
