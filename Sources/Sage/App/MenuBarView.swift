import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Bindable var app: AppModel
    /// 由 SageApp 注入：请求打开主窗口（openWindow 是 Scene 环境值，视图内不可直接用）。
    var openMainWindow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("启用监控", isOn: Binding(
                get: { app.settings.monitoringEnabled },
                set: { on in Task { await app.setMonitoring(on) } }
            ))
            if !app.dtAvailable {
                Label("DEVONthink 未运行，相关规则已暂停", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Text("待确认")
                Spacer()
                Text("\(app.pendingCount)").bold()
            }
            Divider()
            Text("最近活动").font(.caption).foregroundStyle(.secondary)
            if app.recentActivity.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(app.recentActivity.prefix(10)) { entry in
                    Text(entry.text).font(.caption).lineLimit(1)
                }
            }
            Divider()
            dropZone
            Divider()
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                openMainWindow()
            }
            Button("退出 Sage") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
        .task { await app.refreshQueueBadge() }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .frame(height: 56)
            .overlay(Text("拖入文件套用「仅手动」规则").font(.caption).foregroundStyle(.secondary))
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.map(\.path)
                Task { if !paths.isEmpty { await app.handleManualDrop(paths: paths) } }
                return !paths.isEmpty
            }
    }
}
