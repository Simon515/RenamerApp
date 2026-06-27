import SwiftUI

extension Notification.Name {
    /// 菜单栏弹出框请求选择文件夹并触发分析时发送的通知；`object` 为选中的 `[URL]`。
    static let renamerPickFolders = Notification.Name("renamerPickFolders")
}

struct MenuBarPopover: View {
    @MainActor
    var openMainWindow: @MainActor () -> Void
    @MainActor
    var onPickFolders: @MainActor ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("整理选中的文件夹…") {
                pickFolders()
            }
            Button("打开主窗口") { openMainWindow() }
            Button("设置") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
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
