import SwiftUI

struct PlanPreviewView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack {
            if let plan = viewModel.plan {
                Text("共 \(plan.operations.count) 项操作")
                    .font(.headline)

                Picker("整理方式", selection: Binding(
                    get: { plan.operation },
                    set: { viewModel.plan?.operation = $0 }
                )) {
                    Text("复制").tag(CopyOrMove.copy)
                    Text("移动").tag(CopyOrMove.move)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                List {
                    if !plan.duplicateGroups.isEmpty {
                        Section("重复文件组") {
                            duplicateGroupsSection
                        }
                    }

                    Section("操作") {
                        ForEach(planOperationsBinding) { $op in
                            OperationRow(
                                operation: $op,
                                analysis: plan.analyses.first { $0.id == op.analysisID }
                            )
                        }
                    }
                }

                Button("执行整理") {
                    Task {
                        await viewModel.execute(plan: plan, taskName: "manual", operation: plan.operation)
                    }
                }
            } else {
                ContentUnavailableView("暂无整理计划", systemImage: "doc.text.magnifyingglass")
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil || viewModel.successMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil; viewModel.successMessage = nil } }
        )) {
            Button("确定") {
                viewModel.errorMessage = nil
                viewModel.successMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? viewModel.successMessage ?? "")
        }
    }

    private var planOperationsBinding: Binding<[PlanOperation]> {
        Binding(
            get: { viewModel.plan?.operations ?? [] },
            set: { viewModel.plan?.operations = $0 }
        )
    }

    @ViewBuilder
    private var duplicateGroupsSection: some View {
        ForEach(duplicateGroupsBinding) { $group in
            VStack(alignment: .leading, spacing: 4) {
                Text("哈希: \(group.hash.prefix(8))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(group.items) { item in
                    Text(item.url.lastPathComponent)
                        .font(.caption2)
                }
                Picker("保留", selection: Binding(
                    get: { group.keepIndex ?? 0 },
                    set: { group.keepIndex = $0 }
                )) {
                    ForEach(0..<group.items.count, id: \.self) { index in
                        Text(group.items[index].url.lastPathComponent).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: group.keepIndex) { _, _ in
                    Task {
                        await viewModel.rebuildPlan()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var duplicateGroupsBinding: Binding<[DuplicateGroup]> {
        Binding(
            get: { viewModel.plan?.duplicateGroups ?? [] },
            set: { viewModel.plan?.duplicateGroups = $0 }
        )
    }
}

// MARK: - 操作行

private struct OperationRow: View {
    @Binding var operation: PlanOperation
    let analysis: FileAnalysis?
    @State private var isExpanded = false

    private var destinationBinding: Binding<String> {
        Binding(
            get: { operation.destination.path() },
            set: { operation.destination = URL(fileURLWithPath: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $operation.isEnabled)
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(operation.source.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("目标路径", text: destinationBinding)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        if let analysis = analysis, !analysis.tags.isEmpty {
                            Text(analysis.tags.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let analysis = analysis {
                            Text("置信度: \(analysis.confidence, format: .percent)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }

            if isExpanded, let analysis = analysis {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("标题", value: analysis.title ?? "-")
                    LabeledContent("日期", value: analysis.date.map { DateFormatter.shortDate.string(from: $0) } ?? "-")
                    LabeledContent("分类", value: analysis.category ?? "-")
                    LabeledContent("标签", value: analysis.tags.isEmpty ? "-" : analysis.tags.joined(separator: ", "))
                    LabeledContent("置信度", value: analysis.confidence.formatted(.percent))
                    LabeledContent("摘要", value: analysis.summary ?? "-")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}
