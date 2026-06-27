import SwiftUI

@main
struct RenamerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Renamer")
                .frame(width: 400, height: 300)
        }
        .windowResizability(.contentSize)

        Settings {
            Text("Settings")
        }
    }
}
