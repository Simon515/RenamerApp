import SwiftUI

struct TaskEditorView: View {
    @Bindable var taskList: TaskListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack {
            TextField("任务名称", text: $name)
            Button("保存") {
                let task = OrganizationTask(
                    id: UUID(),
                    name: name,
                    sourceFolders: [],
                    templateID: UUID(),
                    destinationFolder: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"),
                    operation: .copy,
                    exportTargets: [],
                    useCloudAI: false
                )
                try? taskList.add(task)
                dismiss()
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
