import SwiftUI

struct RuleEditorView: View {
    @Bindable var model: RuleEditorModel
    var onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sampleForDryRun: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.draft.name.isEmpty ? "编辑规则" : model.draft.name).font(.title2).bold()

            Form {
                TextField("名称", text: $model.draft.name)
                Picker("触发", selection: $model.draft.trigger) {
                    Text("监控自动").tag(TriggerMode.automatic)
                    Text("仅手动").tag(TriggerMode.manualOnly)
                }
                Picker("执行", selection: $model.draft.executionMode) {
                    Text("自动执行").tag(ExecutionMode.automatic)
                    Text("先入确认队列").tag(ExecutionMode.confirmFirst)
                }
                Picker("条件逻辑", selection: $model.draft.conditionLogic) {
                    Text("全部满足").tag(ConditionLogic.all)
                    Text("任一满足").tag(ConditionLogic.any)
                }
            }
            .frame(height: 130)

            GroupBox("动作（按序执行）") {
                ForEach(Array(model.draft.actions.enumerated()), id: \.offset) { idx, action in
                    HStack {
                        Text(RuleEditorModel.describe(action))
                        Spacer()
                        Button(role: .destructive) { model.removeAction(at: idx) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("添加动作") {
                    Button("加 Finder 标签…") { model.addAction(.addFinderTags(["标签"])) }
                    Button("重命名（模板）") { model.addAction(.rename(template: "{title}")) }
                    Button("用 LLM 提取元数据 ✦") { model.addAction(.llmExtractMetadata) }
                    Button("移到废纸篓（需确认）") { model.addAction(.moveToTrash) }
                }
            }

            HStack {
                TextField("试运行样本文件路径", text: $sampleForDryRun)
                Button("试运行") { Task { await model.performDryRun(samplePath: sampleForDryRun) } }
                    .disabled(sampleForDryRun.isEmpty)
            }
            if let dry = model.dryRun {
                GroupBox(dry.matched ? "✅ 命中" : "⛔️ 未命中") {
                    ForEach(dry.resolvedActions, id: \.self) { Text($0).font(.caption) }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { onSave(model.draft); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 460)
    }
}
