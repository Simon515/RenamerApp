import Foundation
import Observation

/// 日志视图模型：列出操作记录，逐条回滚。
@MainActor
@Observable
public final class JournalModel {
    public private(set) var records: [JournalRecord] = []
    public var errorMessage: String?

    private let journal: Journal

    public init(journal: Journal) { self.journal = journal }

    /// 视图主动刷新：清掉旧错误后重载记录。
    public func reload() async {
        errorMessage = nil
        await loadRecords()
    }

    /// 仅重载记录，不清空 errorMessage —— 供回滚在设置错误后刷新，避免抹掉刚设的错误。
    private func loadRecords() async {
        do { records = try await journal.all() }
        catch { errorMessage = error.localizedDescription }
    }

    public func rollback(id: UUID) async {
        errorMessage = nil
        do { try await journal.rollback(id: id) }
        catch { errorMessage = error.localizedDescription }
        await loadRecords()
    }

    public nonisolated static func summary(_ record: JournalRecord) -> String {
        "\(record.ruleName) · \(record.ops.count) 步 · \(record.sourceDescription)"
    }

    public nonisolated static func describe(_ op: ReversibleOp) -> String {
        switch op {
        case .moved(let from, let to): return "移动 \(from) → \(to)"
        case .copied(let to): return "复制到 \(to)"
        case .renamed(let from, let to): return "重命名 \(from) → \(to)"
        case .trashed(let originalPath, _): return "移到废纸篓 \(originalPath)"
        case .addedFinderTags(let tags, let path, _): return "加标签 \(tags.joined(separator: "、")) 于 \(path)"
        }
    }
}
