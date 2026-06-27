import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsViewModel()

    var body: some View {
        TabView {
            Text("通用")
                .tabItem { Label("通用", systemImage: "gear") }
            Text("模板")
                .tabItem { Label("模板", systemImage: "text.quote") }
            Text("AI")
                .tabItem { Label("AI", systemImage: "cpu") }
        }
        .frame(width: 500, height: 350)
    }
}
