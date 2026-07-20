import SwiftUI

/// 单例装配持有者：主窗口与菜单栏共享同一个 AppModel，避免双装配。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            guard model == nil else { return }
            model = await AppModel.bootstrap(supportDirectory: SageApp.supportDirectory)
        }
    }
}

@main
struct SageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    static var supportDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var body: some Scene {
        Window("Sage", id: "main") {
            Group {
                if let app = delegate.model { ContentView(app: app) }
                else { ProgressView("正在启动…") }
            }
            .frame(minWidth: 720, minHeight: 460)
        }

        MenuBarExtra("Sage", systemImage: "leaf") {
            MenuBarScene(delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let app = delegate.model { SettingsView(app: app) }
            else { ProgressView("正在启动…").padding() }
        }
    }
}

/// 菜单栏内容：注入 openWindow，供「打开主窗口」使用。
private struct MenuBarScene: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let app = delegate.model {
            MenuBarView(app: app) { openWindow(id: "main") }
        } else {
            Text("正在启动…").padding()
        }
    }
}
