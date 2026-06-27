import SwiftUI

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView {
            Text("通用")
                .tabItem { Label("通用", systemImage: "gear") }
            Text("模板")
                .tabItem { Label("模板", systemImage: "text.quote") }
            aiTab
                .tabItem { Label("AI", systemImage: "cpu") }
        }
        .frame(width: 500, height: 350)
    }

    @ViewBuilder
    private var aiTab: some View {
        @Bindable var settings = settings
        Form {
            Picker("服务商预设", selection: Binding(
                get: {
                    settings.providerPresets.firstIndex {
                        $0.baseURL == settings.cloudBaseURL && $0.model == settings.cloudModel
                    } ?? -1
                },
                set: { index in
                    if index >= 0 {
                        settings.applyPreset(settings.providerPresets[index])
                    }
                }
            )) {
                Text("自定义").tag(-1)
                ForEach(Array(settings.providerPresets.enumerated()), id: \.offset) { index, preset in
                    Text(preset.name).tag(index)
                }
            }

            TextField("Base URL", text: $settings.cloudBaseURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $settings.cloudAPIKey)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $settings.cloudModel)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }
}
