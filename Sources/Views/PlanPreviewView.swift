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

                List(planOperationsBinding) { $op in
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

                Button("执行整理") {
                    Task {
                        await viewModel.execute(plan: viewModel.plan!, taskName: "manual", operation: plan.operation)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
    }

    private var planOperationsBinding: Binding<[PlanOperation]> {
        Binding(
            get: { viewModel.plan?.operations ?? [] },
            set: { viewModel.plan?.operations = $0 }
        )
    }
}
