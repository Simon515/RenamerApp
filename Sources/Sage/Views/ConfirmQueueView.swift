import SwiftUI

struct ConfirmQueueView: View {
    @Bindable var model: ConfirmQueueModel
    /// 队列变更后回调（供上层刷新待确认角标/菜单栏计数）。
    var onChange: () async -> Void = {}

    var body: some View {
        VStack {
            if model.items.isEmpty {
                ContentUnavailableView("没有待确认项", systemImage: "checkmark.circle")
            } else {
                List(model.items) { item in
                    HStack {
                        Text(ConfirmQueueModel.summary(item))
                        Spacer()
                        Button("批准") { Task { await model.approve(id: item.id); await onChange() } }
                        Button("拒绝", role: .destructive) { Task { await model.reject(id: item.id); await onChange() } }
                    }
                }
            }
        }
        .navigationTitle("待确认队列")
        .toolbar {
            ToolbarItemGroup {
                Button("全部批准") { Task { await model.approveAll(); await onChange() } }.disabled(model.items.isEmpty)
                Button("全部拒绝", role: .destructive) { Task { await model.rejectAll(); await onChange() } }.disabled(model.items.isEmpty)
            }
        }
        .task { await model.reload() }
    }
}
