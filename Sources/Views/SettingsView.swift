import SwiftUI

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gear") }
            templatesTab
                .tabItem { Label("模板", systemImage: "text.quote") }
            aiTab
                .tabItem { Label("AI", systemImage: "cpu") }
        }
        .frame(width: 500, height: 350)
    }

    @ViewBuilder
    private var generalTab: some View {
        @Bindable var settings = settings
        Form {
            Picker("默认操作", selection: Binding(
                get: { settings.defaultOperation },
                set: {
                    settings.defaultOperation = $0
                    settings.save()
                }
            )) {
                Text("复制").tag(CopyOrMove.copy)
                Text("移动").tag(CopyOrMove.move)
            }
            .pickerStyle(.segmented)
        }
        .padding()
    }

    @ViewBuilder
    private var templatesTab: some View {
        @Bindable var settings = settings
        List(settings.templates) { template in
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.headline)
                Text("文件夹: \(template.folderTemplate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("文件名: \(template.fileNameTemplate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 300)
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

            TextField("Base URL", text: Binding(
                get: { settings.cloudBaseURL },
                set: {
                    settings.cloudBaseURL = $0
                    settings.save()
                }
            ))
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: Binding(
                get: { settings.cloudAPIKey },
                set: {
                    settings.cloudAPIKey = $0
                    settings.save()
                }
            ))
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: Binding(
                get: { settings.cloudModel },
                set: {
                    settings.cloudModel = $0
                    settings.save()
                }
            ))
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }
}
