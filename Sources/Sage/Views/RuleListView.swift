import SwiftUI

struct RuleListView: View {
    @Bindable var app: AppModel
    @State private var editing: Rule?
    @State private var showingEditor = false

    var body: some View {
        List {
            ForEach(app.ruleList.rules) { rule in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { newValue in Task { await app.ruleList.setEnabled(newValue, ruleID: rule.id) } }
                    )).labelsHidden()
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(rule.name).font(.headline)
                            if rule.usesLLM { Text("✦").foregroundStyle(.purple) }
                        }
                        Text(scopeSummary(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(rule.trigger == .automatic ? "自动" : "手动")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = rule; showingEditor = true }
                .contextMenu {
                    Button("复制") { Task { await app.ruleList.duplicate(ruleID: rule.id) } }
                    Button("导出 JSON") {
                        if let json = app.ruleList.exportJSON(ruleID: rule.id) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                        }
                    }
                    Divider()
                    Button("删除", role: .destructive) { Task { await app.ruleList.delete(ruleID: rule.id) } }
                }
            }
            .onMove { offsets, dest in Task { await app.ruleList.move(fromOffsets: offsets, toOffset: dest) } }
        }
        .navigationTitle("规则")
        .toolbar {
            ToolbarItem {
                Button {
                    editing = newRuleTemplate(); showingEditor = true
                } label: { Label("新建规则", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let rule = editing {
                RuleEditorView(model: RuleEditorModel(rule: rule, engine: app.dryRunEngine)) { saved in
                    Task {
                        if app.ruleList.rules.contains(where: { $0.id == saved.id }) {
                            await app.ruleList.update(saved)
                        } else {
                            await app.ruleList.add(saved)
                        }
                    }
                }
            }
        }
    }

    private func scopeSummary(_ rule: Rule) -> String {
        rule.scopes.map { scope in
            switch scope {
            case .localFolder(let path, _): return (path as NSString).lastPathComponent
            case .devonthink(let db, let group): return "DT:\(db)\(group)"
            case .manualOnly: return "仅手动"
            }
        }.joined(separator: "、")
    }

    private func newRuleTemplate() -> Rule {
        // 新规则默认「先入确认队列」更安全（spec §7.5 对含 LLM 尤其如此）
        Rule(id: UUID(), name: "新规则", enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [], actions: [], executionMode: .confirmFirst)
    }
}
