import SwiftUI

struct SettingsView: View {
    @Environment(SettingsViewModel.self) private var settings
    @State private var editingTemplate: NamingTemplate?
    @State private var showTemplateEditor = false

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
        .frame(width: 520, height: 400)
        .sheet(isPresented: $showTemplateEditor) {
            if let editingTemplate {
                TemplateEditorSheet(template: editingTemplate) { updated in
                    if let index = settings.templates.firstIndex(where: { $0.id == updated.id }) {
                        settings.templates[index] = updated
                    } else {
                        settings.templates.append(updated)
                    }
                    settings.save()
                }
            }
        }
        .onDisappear {
            settings.save()
        }
    }

    @ViewBuilder
    private var generalTab: some View {
        @Bindable var settings = settings
        Form {
            Picker("默认操作", selection: $settings.defaultOperation) {
                Text("复制").tag(CopyOrMove.copy)
                Text("移动").tag(CopyOrMove.move)
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.defaultOperation) { _, _ in
                settings.save()
            }
        }
        .padding()
    }

    @ViewBuilder
    private var templatesTab: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            List {
                Section("默认模板") {
                    Picker("默认模板", selection: $settings.defaultTemplateID) {
                        ForEach(settings.templates) { template in
                            Text(template.name).tag(template.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: settings.defaultTemplateID) { _, _ in
                        settings.save()
                    }
                }

                Section("自定义模板") {
                    ForEach(Array(settings.templates.enumerated()), id: \.offset) { _, template in
                        HStack {
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
                            Spacer()
                            if template.id == settings.defaultTemplateID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("编辑") {
                                editingTemplate = template
                                showTemplateEditor = true
                            }
                            if settings.templates.count > 1 {
                                Button("删除", role: .destructive) {
                                    deleteTemplate(template)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Button("添加模板") {
                    editingTemplate = NamingTemplate(id: UUID(), name: "", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
                    showTemplateEditor = true
                }
                Spacer()
            }
            .padding()
        }
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
                .onSubmit { settings.save() }
            SecureField("API Key", text: $settings.cloudAPIKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit { settings.save() }
            TextField("Model", text: $settings.cloudModel)
                .textFieldStyle(.roundedBorder)
                .onSubmit { settings.save() }

            Text("API Key 安全存储于系统钥匙串（Keychain）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let keychainError = settings.keychainError {
                Text(keychainError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func deleteTemplate(_ template: NamingTemplate) {
        guard settings.templates.count > 1 else { return }
        settings.templates.removeAll { $0.id == template.id }
        if settings.defaultTemplateID == template.id {
            settings.defaultTemplateID = settings.templates.first?.id
        }
        settings.save()
    }
}

struct TemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var template: NamingTemplate
    let onSave: (NamingTemplate) -> Void

    init(template: NamingTemplate, onSave: @escaping (NamingTemplate) -> Void) {
        self._template = State(initialValue: template)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("名称", text: $template.name)
            TextField("文件夹模板", text: $template.folderTemplate)
                .textFieldStyle(.roundedBorder)
            TextField("文件名模板", text: $template.fileNameTemplate)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(template)
                    dismiss()
                }
                .disabled(template.name.isEmpty || template.folderTemplate.isEmpty || template.fileNameTemplate.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 180)
    }
}
