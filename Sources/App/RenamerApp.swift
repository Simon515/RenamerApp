import SwiftUI

@main
struct RenamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
        }
        .defaultSize(width: 600, height: 500)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
