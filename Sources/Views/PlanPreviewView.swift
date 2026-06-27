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
                            HStack {
                                Toggle("", isOn: $op.isEnabled)
                                    .labelsHidden()
                                VStack(alignment: .leading) {
                                    Text(op.source.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(op.destination.path())
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Button("执行整理") {
                    Task {
                        await viewModel.execute(plan: viewModel.plan!, taskName: "manual", operation: plan.operation)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("确定") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
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
