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

    public func reload() async {
        do { items = try await queue.all(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    public func approve(id: UUID) async {
        let outcome = await coordinator.approve(pendingID: id)
        if case .failed(_, _, let message) = outcome { errorMessage = message }
        await reload()
    }

    public func reject(id: UUID) async {
        do { try await coordinator.reject(pendingID: id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        await reload()
    }

    public func approveAll() async {
        for item in items { _ = await coordinator.approve(pendingID: item.id) }
        await reload()
    }

    public func rejectAll() async {
        for item in items { try? await coordinator.reject(pendingID: item.id) }
        await reload()
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
