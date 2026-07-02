import SwiftUI

extension Notification.Name {
    /// 菜单栏弹出框请求选择文件夹并触发分析时发送的通知；`object` 为选中的 `[URL]`。
    static let renamerPickFolders = Notification.Name("renamerPickFolders")
    /// 菜单栏弹出框请求直接运行已保存任务时发送的通知；`object` 为任务 `UUID`。
    static let renamerRunTask = Notification.Name("renamerRunTask")
}

struct MenuBarPopover: View {
    @MainActor
    var openMainWindow: @MainActor () -> Void
    @MainActor
    var onPickFolders: @MainActor ([URL]) -> Void

    @State private var taskList = TaskListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("整理选中的文件夹…") {
                pickFolders()
            }

            if !taskList.tasks.isEmpty {
                Divider()
                Text("最近任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(taskList.tasks.prefix(5)) { task in
                    Button(task.name) {
                        NotificationCenter.default.post(name: .renamerRunTask, object: task.id)
                        onPickFolders([])
                    }
                }
                Divider()
            }

            Button("打开主窗口") { openMainWindow() }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
        .onAppear {
            try? taskList.load()
        }
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            onPickFolders(panel.urls)
        }
    }
}
