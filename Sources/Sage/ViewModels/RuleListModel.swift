import Foundation
import Observation

/// 规则库视图模型：加载、启停、重排、复制、增删、导出。
@MainActor
@Observable
public final class RuleListModel {
    public private(set) var rules: [Rule] = []
    public var errorMessage: String?

    private let store: RuleStore

    public init(store: RuleStore) { self.store = store }

    public func reload() async {
        do { rules = try await store.load().rules; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    public func setEnabled(_ enabled: Bool, ruleID: UUID) async {
        guard let idx = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[idx].enabled = enabled
        await save()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) async {
        // 复刻 SwiftUI `move(fromOffsets:toOffset:)` 语义，避免 ViewModel 依赖 SwiftUI
        let moving = fromOffsets.map { rules[$0] }
        for index in fromOffsets.sorted(by: >) { rules.remove(at: index) }
        let adjusted = toOffset - fromOffsets.filter { $0 < toOffset }.count
        rules.insert(contentsOf: moving, at: adjusted)
        await save()
    }

    public func duplicate(ruleID: UUID) async {
        guard let idx = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        var copy = rules[idx]
        copy.id = UUID()
        copy.name = "\(copy.name) 副本"
        rules.insert(copy, at: idx + 1)
        await save()
    }

    public func delete(ruleID: UUID) async {
        rules.removeAll { $0.id == ruleID }
        await save()
    }

    public func add(_ rule: Rule) async {
        rules.append(rule)
        await save()
    }

    public func update(_ rule: Rule) async {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        await save()
    }

    /// 存在则覆盖、不存在则追加（编辑器保存统一入口，避免调用方分辨新增/修改）。
    public func upsert(_ rule: Rule) async {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) { rules[idx] = rule }
        else { rules.append(rule) }
        await save()
    }

    /// 当前规则快照，供监控总管重建 watcher 用；从未加载过则先加载。
    public func currentRulesSnapshot() async -> [Rule] {
        if rules.isEmpty { await reload() }
        return rules
    }

    public func exportJSON(ruleID: UUID) -> String? {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rule) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save() async {
        do { try await store.save(RuleLibrary(version: RuleLibrary.currentVersion, rules: rules)); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
