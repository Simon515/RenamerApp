import Foundation
import SwiftUI

@MainActor
@Observable
final class HistoryViewModel {
    var records: [FileOperationRecord] = []
    var userMessage: UserMessage?
    var isLoading = false

    private let service = RollbackService()

    func load() async {
        isLoading = true
        defer { isLoading = false }
        records = await service.listRecords()
    }

    /// 回滚指定记录；成功后删除记录文件并刷新列表。
    func rollback(record: FileOperationRecord) async {
        do {
            try await service.rollback(record: record)
            try? await service.deleteRecord(id: record.id)
            userMessage = .success("已回滚「\(record.taskName)」")
            await load()
        } catch {
            userMessage = .error(error.localizedDescription)
        }
    }

    /// 删除记录文件（不回滚），用于记录已过期或用户希望清理。
    func deleteRecord(_ record: FileOperationRecord) async {
        do {
            try await service.deleteRecord(id: record.id)
            await load()
        } catch {
            userMessage = .error(error.localizedDescription)
        }
    }
}
