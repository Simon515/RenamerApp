import Foundation

/// DT 动作真实执行器 + DT 回滚（spec §5）。逻辑经 FakeRunner 测试；真实执行手动验证。
public struct DTActions: DTActionExecutor, DTReverting {
    private let runner: any AppleScriptRunning
    private let isRunning: @Sendable () -> Bool

    public init(runner: any AppleScriptRunning = NSAppleScriptRunner(),
                isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning) {
        self.runner = runner
        self.isRunning = isRunning
    }

    public func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp] {
        guard isRunning() else { throw DTError.notRunning }
        switch action {
        case .dtImport(let database, let groupPath, let tags, let noteTemplate):
            guard case .local(let path) = location else { throw DTError.needsLocalFile }
            let uuid = try await runner.run(DTScriptBuilder.importScript(
                filePath: path, database: database, groupPath: groupPath,
                tags: tags, note: noteTemplate))
            return [.dtImported(uuid: uuid, database: database)]

        case .dtRename(let template):
            let uuid = try recordUUID(of: location)
            let oldName = try await runner.run(DTScriptBuilder.renameScript(uuid: uuid, newName: template))
            return [.dtRenamed(uuid: uuid, from: oldName, to: template)]

        case .dtAddTags(let tags):
            let uuid = try recordUUID(of: location)
            let prevRaw = try await runner.run(DTScriptBuilder.addTagsScript(uuid: uuid, tags: tags))
            let previous = prevRaw.split(separator: "\n").map(String.init)
            return [.dtAddedTags(tags, uuid: uuid, previous: previous)]

        case .dtMoveToGroup(let database, let groupPath):
            let uuid = try recordUUID(of: location)
            let prevRaw = try await runner.run(DTScriptBuilder.moveScript(
                uuid: uuid, toDatabase: database, toGroupPath: groupPath))
            let parts = prevRaw.split(separator: "\t", maxSplits: 1).map(String.init)
            let fromDB = parts.first ?? ""
            let fromGroup = parts.count > 1 ? parts[1] : ""
            return [.dtMoved(uuid: uuid, fromDatabase: fromDB, fromGroup: fromGroup,
                             toDatabase: database, toGroup: groupPath)]

        default:
            throw ActionExecutionError.unsupportedAction("非 DEVONthink 动作")
        }
    }

    public func revert(_ op: ReversibleOp) async throws {
        guard isRunning() else { throw DTError.notRunning }
        switch op {
        case .dtImported(let uuid, _):
            _ = try await runner.run(DTScriptBuilder.deleteScript(uuid: uuid))
        case .dtRenamed(let uuid, let from, _):
            _ = try await runner.run(DTScriptBuilder.setNameScript(uuid: uuid, name: from))
        case .dtAddedTags(_, let uuid, let previous):
            _ = try await runner.run(DTScriptBuilder.setTagsScript(uuid: uuid, tags: previous))
        case .dtMoved(let uuid, let fromDatabase, let fromGroup, _, _):
            _ = try await runner.run(DTScriptBuilder.moveScript(
                uuid: uuid, toDatabase: fromDatabase, toGroupPath: fromGroup))
        default:
            throw JournalError.rollbackFailed("非 DEVONthink 操作不应到达 DTActions.revert")
        }
    }

    private func recordUUID(of location: FileLocation) throws -> String {
        guard case .devonthink(let uuid, _, _) = location else { throw DTError.needsLocalFile }
        return uuid
    }
}
