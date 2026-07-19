import SwiftUI

struct ConfirmQueueView: View {
    @Bindable var model: ConfirmQueueModel

    var body: some View {
        VStack {
            if model.items.isEmpty {
                ContentUnavailableView("没有待确认项", systemImage: "checkmark.circle")
            } else {
                List(model.items) { item in
                    HStack {
                        Text(ConfirmQueueModel.summary(item))
                        Spacer()
                        Button("批准") { Task { await model.approve(id: item.id) } }
                        Button("拒绝", role: .destructive) { Task { await model.reject(id: item.id) } }
                    }
                }
            }
        }
        .navigationTitle("待确认队列")
        .toolbar {
            ToolbarItemGroup {
                Button("全部批准") { Task { await model.approveAll() } }.disabled(model.items.isEmpty)
                Button("全部拒绝", role: .destructive) { Task { await model.rejectAll() } }.disabled(model.items.isEmpty)
            }
        }
        .task { await model.reload() }
    }
}
