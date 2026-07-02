import Foundation

/// 整理过程中发生的错误，携带已完成的操作记录以支持部分回滚。
struct OrganizerError: LocalizedError, Sendable {
    let partialRecord: FileOperationRecord
    let underlying: Error

    var errorDescription: String? {
        "整理未完成：\(underlying.localizedDescription)（已完成 \(partialRecord.moves.count) 项）"
    }
}

/// 整理执行结果：操作记录 + 因目标已存在而跳过的数量（非致命）。
struct ExecutionResult: Sendable {
    let record: FileOperationRecord
    let skippedCount: Int
}

actor Organizer {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager = PluginManager()) {
        self.pluginManager = pluginManager
    }

    /// 执行整理计划。成功（含目标已存在被跳过）返回 `ExecutionResult`；
    /// 中途发生真正的文件系统错误时抛 `OrganizerError`，携带已完成操作的记录以支持部分回滚。
    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove = .copy) async throws -> ExecutionResult {
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
                        Log.organizer.error("导出失败 [\(pluginID, privacy: .public)]：\(error.localizedDescription, privacy: .public)")
                        exports.append(FileOperationRecord.Export(pluginID: pluginID, details: error.localizedDescription))
                    }
                }
            }
        } catch {
            let partialRecord = FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
            throw OrganizerError(partialRecord: partialRecord, underlying: error)
        }

        let record = FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: exports)
        return ExecutionResult(record: record, skippedCount: skippedCount)
    }
}
