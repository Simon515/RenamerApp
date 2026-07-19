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
                Section("作用域") {
                    ForEach(Array(model.draft.scopes.enumerated()), id: \.offset) { idx, scope in
                        HStack {
                            if case .devonthink(let db, let group) = scope {
                                TextField("数据库", text: Binding(
                                    get: { db },
                                    set: { model.draft.scopes[idx] = .devonthink(database: $0, groupPath: group) }))
                                TextField("组路径（/开头）", text: Binding(
                                    get: { group },
                                    set: { model.draft.scopes[idx] = .devonthink(database: db, groupPath: $0) }))
                            } else {
                                Text(Self.scopeLabel(scope)).lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) { model.draft.scopes.remove(at: idx) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Menu("添加作用域") {
                        Button("本地文件夹…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                model.draft.scopes.append(.localFolder(path: url.path, recursive: true))
                            }
                        }
                        Button("DEVONthink 组") {
                            model.draft.scopes.append(.devonthink(database: "数据库名", groupPath: "/收件箱"))
                        }
                        Button("仅手动") { model.draft.scopes.append(.manualOnly) }
                    }
                }
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
            .frame(minHeight: 130, maxHeight: 280)

            GroupBox("动作（按序执行）") {
                ForEach(Array(model.draft.actions.enumerated()), id: \.offset) { idx, action in
                    HStack(alignment: .top) {
                        actionRow(idx: idx, action: action)
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
                    Divider()
                    Button("导入 DEVONthink…") {
                        model.addAction(.dtImport(database: "数据库名", groupPath: "/收件箱", tags: [], noteTemplate: nil))
                    }
                    Button("DEVONthink 内重命名") { model.addAction(.dtRename(template: "{title}")) }
                    Button("DEVONthink 加标签") { model.addAction(.dtAddTags(["标签"])) }
                    Button("DEVONthink 移动到组") { model.addAction(.dtMoveToGroup(database: "数据库名", groupPath: "/已归档")) }
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

    /// DT 动作就地参数编辑；其余动作显示描述文本。
    @ViewBuilder
    private func actionRow(idx: Int, action: Action) -> some View {
        switch action {
        case .dtImport(let db, let group, let tags, let note):
            VStack(alignment: .leading) {
                Text("导入 DEVONthink").font(.caption).foregroundStyle(.secondary)
                TextField("数据库", text: Binding(
                    get: { db },
                    set: { model.draft.actions[idx] = .dtImport(database: $0, groupPath: group, tags: tags, noteTemplate: note) }))
                TextField("组路径", text: Binding(
                    get: { group },
                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: $0, tags: tags, noteTemplate: note) }))
                TextField("标签（逗号分隔）", text: Binding(
                    get: { tags.joined(separator: ",") },
                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: group,
                        tags: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                        noteTemplate: note) }))
                TextField("备注模板（可用 {summary}）", text: Binding(
                    get: { note ?? "" },
                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: group, tags: tags,
                        noteTemplate: $0.isEmpty ? nil : $0) }))
            }
        case .dtRename(let template):
            VStack(alignment: .leading) {
                Text("DEVONthink 内重命名").font(.caption).foregroundStyle(.secondary)
                TextField("名称模板", text: Binding(
                    get: { template },
                    set: { model.draft.actions[idx] = .dtRename(template: $0) }))
            }
        case .dtAddTags(let tags):
            VStack(alignment: .leading) {
                Text("DEVONthink 加标签").font(.caption).foregroundStyle(.secondary)
                TextField("标签（逗号分隔）", text: Binding(
                    get: { tags.joined(separator: ",") },
                    set: { model.draft.actions[idx] = .dtAddTags(
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }))
            }
        case .dtMoveToGroup(let db, let group):
            VStack(alignment: .leading) {
                Text("DEVONthink 移动到组").font(.caption).foregroundStyle(.secondary)
                TextField("数据库", text: Binding(
                    get: { db },
                    set: { model.draft.actions[idx] = .dtMoveToGroup(database: $0, groupPath: group) }))
                TextField("组路径", text: Binding(
                    get: { group },
                    set: { model.draft.actions[idx] = .dtMoveToGroup(database: db, groupPath: $0) }))
            }
        default:
            Text(RuleEditorModel.describe(action))
        }
    }

    static func scopeLabel(_ scope: RuleScope) -> String {
        switch scope {
        case .localFolder(let path, let recursive):
            return "\((path as NSString).lastPathComponent)\(recursive ? "（含子目录）" : "")"
        case .devonthink(let db, let group): return "DT：\(db)\(group)"
        case .manualOnly: return "仅手动"
        }
    }
}
