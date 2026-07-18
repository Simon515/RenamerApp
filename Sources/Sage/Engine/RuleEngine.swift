import Foundation

/// 规则匹配引擎：事件 → 按序匹配规则 → ActionPlan（spec §3、§4）。
public struct RuleEngine: Sendable {
    private let evaluator: ConditionEvaluator

    public init(provider: any FactsProvider) {
        self.evaluator = ConditionEvaluator(provider: provider)
    }

    public func plan(for event: FileEvent, rules: [Rule]) async -> ActionPlan {
        var planned: [PlannedActions] = []
        for rule in rules {
            guard rule.enabled else { continue }
            guard rule.scopes.contains(where: { event.isCovered(by: $0) }) else { continue }
            // 自动来源事件不触发「仅手动」规则；手动来源事件两种都可触发
            if event.source != .manual && rule.trigger == .manualOnly { continue }

            guard await matches(rule, event: event) else { continue }

            planned.append(PlannedActions(
                ruleID: rule.id, ruleName: rule.name, location: event.location,
                actions: rule.actions, requiresConfirmation: rule.requiresConfirmation))

            // 默认首中即停；含 continueMatching 才放行后续规则
            if !rule.actions.contains(.continueMatching) { break }
        }
        return ActionPlan(event: event, planned: planned)
    }

    /// 条件按成本档次升序求值：all 短路失败，any 短路成功。
    /// 求值抛错（LLM/提取失败）视为不匹配——不阻塞其他规则（spec §8），
    /// 错误的记录与重试由 Execution 层负责（第 3/5 份计划）。
    private func matches(_ rule: Rule, event: FileEvent) async -> Bool {
        if rule.conditions.isEmpty { return true }
        let ordered = rule.conditions.sorted { $0.tier < $1.tier }
        do {
            switch rule.conditionLogic {
            case .all:
                for condition in ordered {
                    if !(try await evaluator.evaluate(condition, at: event.location)) { return false }
                }
                return true
            case .any:
                for condition in ordered {
                    if try await evaluator.evaluate(condition, at: event.location) { return true }
                }
                return false
            }
        } catch {
            return false
        }
    }
}
