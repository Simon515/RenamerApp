import SwiftUI

struct PlanPreviewView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack {
            if let plan = viewModel.plan {
                VStack(spacing: 8) {
                    Text("共 \(plan.operations.count) 项操作")
                        .font(.headline)

                    HStack(spacing: 16) {
                        StatBadge(label: "已启用", value: "\(plan.operations.filter(\.isEnabled).count)")
                        StatBadge(label: "重复组", value: "\(plan.duplicateGroups.count)")
                        StatBadge(label: "平均置信度", value: averageConfidenceText)
                    }
                }

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
                            duplicateGroupStrategyMenu
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
        .userMessageAlert($viewModel.userMessage)
    }

    private var averageConfidenceText: String {
        guard let plan = viewModel.plan, !plan.analyses.isEmpty else { return "-" }
        let avg = plan.analyses.map(\.confidence).reduce(0, +) / Double(plan.analyses.count)
        return avg.formatted(.percent.precision(.fractionLength(0)))
    }

    private var planOperationsBinding: Binding<[PlanOperation]> {
        Binding(
            get: { viewModel.plan?.operations ?? [] },
            set: { viewModel.plan?.operations = $0 }
        )
    }

    @ViewBuilder
    private var duplicateGroupStrategyMenu: some View {
        HStack {
            Text("保留策略")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu("应用策略") {
                Button("每组保留第一个") { applyKeepStrategy(.first) }
                Button("每组保留最新") { applyKeepStrategy(.newest) }
                Button("全部保留") { applyKeepStrategy(.all) }
            }
        }
    }

    private enum KeepStrategy {
        case first, newest, all
    }

    private func applyKeepStrategy(_ strategy: KeepStrategy) {
        guard var groups = viewModel.plan?.duplicateGroups else { return }
        switch strategy {
        case .first:
            for i in groups.indices {
                groups[i].keepIndex = 0
            }
        case .newest:
            for i in groups.indices {
                groups[i].keepIndex = newestIndex(in: groups[i])
            }
        case .all:
            for i in groups.indices {
                groups[i].keepIndex = nil
            }
        }
        viewModel.plan?.duplicateGroups = groups
        Task {
            await viewModel.rebuildPlan()
        }
    }

    private func newestIndex(in group: DuplicateGroup) -> Int? {
        let dates = group.items.map { $0.modificationDate ?? Date.distantPast }
        guard let maxDate = dates.max() else { return nil }
        return dates.firstIndex { $0 == maxDate }
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

private struct StatBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
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
