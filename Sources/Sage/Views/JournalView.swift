import SwiftUI

struct JournalView: View {
    @Bindable var model: JournalModel

    var body: some View {
        VStack {
            if model.records.isEmpty {
                ContentUnavailableView("暂无操作记录", systemImage: "clock")
            } else {
                List(model.records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(JournalModel.summary(record)).font(.subheadline)
                            Spacer()
                            Button("回滚") { Task { await model.rollback(id: record.id) } }
                        }
                        ForEach(Array(record.ops.enumerated()), id: \.offset) { _, op in
                            Text(JournalModel.describe(op)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("日志")
        .task { await model.reload() }
    }
}
