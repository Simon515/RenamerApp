import Foundation

/// 从 RuleStore 读取当前规则；读失败返回空（不阻塞管线）。
public actor RuleStoreRulesProvider: RulesProviding {
    private let store: RuleStore
    public init(store: RuleStore) { self.store = store }
    public func currentRules() async -> [Rule] {
        (try? await store.load())?.rules ?? []
    }
}
