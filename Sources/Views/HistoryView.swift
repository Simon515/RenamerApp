import SwiftUI

struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.records.isEmpty {
                    ContentUnavailableView("暂无整理记录", systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(viewModel.records) { record in
                            RecordRow(record: record) {
                                await viewModel.rollback(record: record)
                            } onDelete: {
                                await viewModel.deleteRecord(record)
                            }
                        }
                    }
                }
            }
            .navigationTitle("整理历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .userMessageAlert($viewModel.userMessage)
        .task {
            await viewModel.load()
        }
    }
}

// MARK: - 记录行

private struct RecordRow: View {
    let record: FileOperationRecord
    let onRollback: () async -> Void
    let onDelete: () async -> Void
    @State private var showRollbackConfirm = false

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: record.timestamp)
    }

    private var operationSummary: String {
        let copyCount = record.moves.filter { $0.operation == .copy }.count
        let moveCount = record.moves.filter { $0.operation == .move }.count
        var parts: [String] = []
        if copyCount > 0 { parts.append("\(copyCount) 个复制") }
        if moveCount > 0 { parts.append("\(moveCount) 个移动") }
        return parts.isEmpty ? "无文件操作" : parts.joined(separator: "，")
    }

    private var exportCount: Int {
        record.exports.filter { !$0.details.contains("失败") && !$0.details.contains("error") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.taskName)
                    .font(.headline)
                Spacer()
                Text(dateString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(record.moves.count) 个文件：\(operationSummary)")
                .font(.subheadline)
            if exportCount > 0 {
                Text("导出 \(exportCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("回滚", role: .destructive) {
                    showRollbackConfirm = true
                }
                Spacer()
                Button("删除记录", role: .destructive) {
                    Task { await onDelete() }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "确认回滚「\(record.taskName)」？",
            isPresented: $showRollbackConfirm,
            titleVisibility: .visible
        ) {
            Button("回滚", role: .destructive) {
                Task { await onRollback() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("复制类操作回滚会删除目标处的文件；移动类操作会尽量移回源路径。此操作无法撤销。")
        }
    }
}
