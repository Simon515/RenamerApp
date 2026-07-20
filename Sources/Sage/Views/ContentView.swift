import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case rules = "规则"
    case queue = "待确认"
    case journal = "日志"
    var id: String { rawValue }
}

struct ContentView: View {
    @Bindable var app: AppModel
    @State private var selection: SidebarItem? = .rules

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                HStack {
                    Text(item.rawValue)
                    if item == .queue, app.pendingCount > 0 {
                        Spacer()
                        Text("\(app.pendingCount)")
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red)).foregroundStyle(.white)
                    }
                }.tag(Optional(item))
            }
            .navigationTitle("Sage")
            .frame(minWidth: 180)
        } detail: {
            switch selection ?? .rules {
            case .rules: RuleListView(app: app)
            case .queue: ConfirmQueueView(model: app.confirmQueue) { await app.refreshQueueBadge() }
            case .journal: JournalView(model: app.journal)
            }
        }
        .task {
            await app.ruleList.reload()
            await app.confirmQueue.reload()
            await app.journal.reload()
            await app.refreshQueueBadge()
        }
        .alert("出错了", isPresented: Binding(
            get: { activeError != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            Button("好") { clearErrors() }
        } message: { Text(activeError ?? "") }
    }

    /// 三个子视图模型中第一个非空的错误。
    private var activeError: String? {
        app.ruleList.errorMessage ?? app.confirmQueue.errorMessage ?? app.journal.errorMessage
    }

    private func clearErrors() {
        app.ruleList.errorMessage = nil
        app.confirmQueue.errorMessage = nil
        app.journal.errorMessage = nil
    }
}
