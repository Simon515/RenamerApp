import Foundation
import Observation

/// 试运行结果：仅匹配预览，不执行。
public struct DryRunResult: Sendable, Equatable {
    public var matched: Bool
    public var ruleName: String
    public var resolvedActions: [String]
    public init(matched: Bool, ruleName: String, resolvedActions: [String]) {
        self.matched = matched; self.ruleName = ruleName; self.resolvedActions = resolvedActions
    }
}

/// 规则编辑器视图模型：编辑草稿 + 试运行预览。
@MainActor
@Observable
public final class RuleEditorModel {
    public var draft: Rule
    public var dryRun: DryRunResult?
    public var errorMessage: String?

    private let engine: RuleEngine

    public init(rule: Rule, engine: RuleEngine) {
        self.draft = rule
        self.engine = engine
    }

    public var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.actions.isEmpty
    }

    public func addCondition(_ c: Condition) { draft.conditions.append(c) }
    public func removeCondition(at index: Int) {
        guard draft.conditions.indices.contains(index) else { return }
        draft.conditions.remove(at: index)
    }
    public func addAction(_ a: Action) { draft.actions.append(a) }
    public func removeAction(at index: Int) {
        guard draft.actions.indices.contains(index) else { return }
        draft.actions.remove(at: index)
    }

    public func performDryRun(samplePath: String) async {
        let event = FileEvent(location: .local(path: samplePath), source: .manual)
        let plan = await engine.plan(for: event, rules: [draft])
        if let matched = plan.planned.first {
            dryRun = DryRunResult(matched: true, ruleName: matched.ruleName,
                                  resolvedActions: matched.actions.map { Self.describe($0) })
        } else {
            dryRun = DryRunResult(matched: false, ruleName: draft.name, resolvedActions: [])
        }
    }

    /// 动作 → 中文描述。
    public nonisolated static func describe(_ action: Action) -> String {
        switch action {
        case .moveTo(let path): return "移动到 \(path)"
        case .copyTo(let path): return "复制到 \(path)"
        case .rename(let template): return "重命名为 \(template)"
        case .addFinderTags(let tags): return "加 Finder 标签 \(tags.joined(separator: "、"))"
        case .moveToTrash: return "移到废纸篓"
        case .dtImport(let db, let group, _, _): return "导入 DEVONthink：\(db)\(group)"
        case .dtRename(let template): return "DEVONthink 内重命名为 \(template)"
        case .dtAddTags(let tags): return "DEVONthink 加标签 \(tags.joined(separator: "、"))"
        case .dtMoveToGroup(let db, let group): return "DEVONthink 移动到 \(db)\(group)"
        case .llmExtractMetadata: return "用 LLM 提取元数据"
        case .llmRename(let instruction): return "用 LLM 命名（\(instruction)）"
        case .continueMatching: return "继续匹配后续规则"
        }
    }
}
