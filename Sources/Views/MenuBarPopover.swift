import SwiftUI

struct MenuBarPopover: View {
    var openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("整理选中的文件夹…") { }
            Button("打开主窗口") { openMainWindow() }
            Button("设置") { }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
    }
}
