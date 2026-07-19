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
            case .queue: ConfirmQueueView(model: app.confirmQueue)
            case .journal: JournalView(model: app.journal)
            }
        }
        .task {
            await app.ruleList.reload()
            await app.confirmQueue.reload()
            await app.journal.reload()
            await app.refreshQueueBadge()
        }
    }
}
