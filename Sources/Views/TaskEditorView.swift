import SwiftUI

struct TaskEditorView: View {
    @Bindable var taskList: TaskListViewModel
    @Environment(SettingsViewModel.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sourceFolders: [URL] = []
    @State private var destinationFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer")
    @State private var selectedTemplateID: UUID?
    @State private var operation: CopyOrMove = .copy
    @State private var useCloudAI = false
    @State private var useDEVONthink = false
    @State private var devonthinkDatabase = ""
    @State private var devonthinkGroup = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        Form {
            TextField("任务名称", text: $name)

            Section("来源") {
                Button("选择来源文件夹…") {
                    pickFolders { sourceFolders = $0 }
                }
                if !sourceFolders.isEmpty {
                    Text(sourceFolders.map(\.path).joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

            Section("目标") {
                Button("选择目标文件夹…") {
                    pickFolder { destinationFolder = $0 }
                }
                Text(destinationFolder.path())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker("模板", selection: $selectedTemplateID) {
                ForEach(taskList.templates) { template in
                    Text(template.name).tag(template.id as UUID?)
                }
            }

            Picker("操作", selection: $operation) {
                Text("复制").tag(CopyOrMove.copy)
                Text("移动").tag(CopyOrMove.move)
            }
            .pickerStyle(.segmented)

            Toggle("使用 Cloud AI", isOn: $useCloudAI)

            Toggle("导出到 DEVONthink", isOn: $useDEVONthink)
            if useDEVONthink {
                TextField("数据库名称", text: $devonthinkDatabase)
                TextField("组路径", text: $devonthinkGroup)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .disabled(name.isEmpty || sourceFolders.isEmpty || selectedTemplateID == nil)
            }
        }
        .padding()
        .frame(width: 500, height: 420)
        .onAppear {
            operation = settings.defaultOperation
            selectedTemplateID = taskList.templates.first?.id
        }
        .alert("保存失败", isPresented: $showError) {
            Button("确定") { showError = false }
        } message: {
            Text(errorMessage ?? "无法保存任务")
        }
    }

    private func pickFolders(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            completion(panel.urls)
        }
    }

    private func pickFolder(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func save() {
        guard let templateID = selectedTemplateID else { return }
        var exportTargets: [ExportTarget] = []
        if useDEVONthink, !devonthinkDatabase.isEmpty, !devonthinkGroup.isEmpty {
            exportTargets.append(.devonthink(database: devonthinkDatabase, group: devonthinkGroup))
        }
        let task = OrganizationTask(
            id: UUID(),
            name: name,
            sourceFolders: sourceFolders,
            templateID: templateID,
            destinationFolder: destinationFolder,
            operation: operation,
            exportTargets: exportTargets,
            useCloudAI: useCloudAI
        )
        do {
            try taskList.add(task)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
