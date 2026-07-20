import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var apiKey: String = ""
    @State private var draft: SageSettings = .defaults

    var body: some View {
        TabView {
            Form {
                Toggle("开机自动启动", isOn: $draft.launchAtLogin)
                Toggle("启用监控", isOn: $draft.monitoringEnabled)
            }.tabItem { Label("通用", systemImage: "gear") }.padding()

            Form {
                Toggle("启用 LLM 增强", isOn: $draft.provider.enabled)
                TextField("服务地址（baseURL）", text: $draft.provider.baseURL)
                TextField("模型", text: $draft.provider.model)
                SecureField("API Key（存 Keychain）", text: $apiKey)
                TextField("每日调用上限（留空=不限）", value: $draft.dailyLLMBudget, format: .number)
            }.tabItem { Label("AI", systemImage: "sparkles") }.padding()
        }
        .frame(width: 460, height: 260)
        .onAppear { draft = app.settings }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task { await app.applySettings(draft, apiKey: apiKey.isEmpty ? nil : apiKey) }
                }
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("好") { app.errorMessage = nil }
        } message: { Text(app.errorMessage ?? "") }
        .alert("已保存", isPresented: Binding(
            get: { app.infoMessage != nil },
            set: { if !$0 { app.infoMessage = nil } }
        )) {
            Button("好") { app.infoMessage = nil }
        } message: { Text(app.infoMessage ?? "") }
    }
}
