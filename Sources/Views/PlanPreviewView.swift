import SwiftUI

struct PlanPreviewView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack {
            if let plan = viewModel.plan {
                Text("共 \(plan.operations.count) 项操作")
                    .font(.headline)

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
                        await viewModel.execute(plan: viewModel.plan!, taskName: "manual")
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
