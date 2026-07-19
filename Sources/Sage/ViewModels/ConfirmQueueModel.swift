import Foundation
import Observation

/// 确认队列视图模型：列出待确认项，批准/拒绝（含批量）。
@MainActor
@Observable
public final class ConfirmQueueModel {
    public private(set) var items: [PendingItem] = []
    public var errorMessage: String?

    private let queue: ConfirmQueue
    private let coordinator: Coordinator

    public init(queue: ConfirmQueue, coordinator: Coordinator) {
        self.queue = queue; self.coordinator = coordinator
    }

    /// 视图主动刷新：清掉旧错误后重载列表。
    public func reload() async {
        errorMessage = nil
        await loadItems()
    }

    /// 仅重载列表，不清空 errorMessage —— 供操作路径在设置错误后刷新，避免把刚设的错误抹掉。
    private func loadItems() async {
        do { items = try await queue.all() }
        catch { errorMessage = error.localizedDescription }
    }

    public func approve(id: UUID) async {
        errorMessage = nil
        let outcome = await coordinator.approve(pendingID: id)
        if case .failed(_, _, let message) = outcome { errorMessage = message }
        await loadItems()
    }

    public func reject(id: UUID) async {
        errorMessage = nil
        do { try await coordinator.reject(pendingID: id) }
        catch { errorMessage = error.localizedDescription }
        await loadItems()
    }

    public func approveAll() async {
        errorMessage = nil
        for item in items { _ = await coordinator.approve(pendingID: item.id) }
        await loadItems()
    }

    public func rejectAll() async {
        errorMessage = nil
        for item in items { try? await coordinator.reject(pendingID: item.id) }
        await loadItems()
    }

    /// 「源 → 动作序列」一行摘要。
    public nonisolated static func summary(_ item: PendingItem) -> String {
        let source: String
        switch item.event.location {
        case .local(let path): source = (path as NSString).lastPathComponent
        case .devonthink(_, let db, let group): source = "\(db)\(group)"
        }
        let actions = item.planned.actions.map { RuleEditorModel.describe($0) }.joined(separator: " → ")
        return "\(source)：\(actions)"
    }
}
