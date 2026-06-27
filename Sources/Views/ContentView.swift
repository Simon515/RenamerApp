import SwiftUI

struct ContentView: View {
    @Environment(SettingsViewModel.self) private var settings
    @State private var viewModel = MainViewModel()
    @State private var taskList = TaskListViewModel()
    @State private var showTaskEditor = false
    @State private var operation: CopyOrMove = .copy

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Renamer")
                    .font(.largeTitle)
                DropZoneView { urls in
                    Task {
                        let template = settings.defaultTemplate
                        await viewModel.analyze(folders: urls, task: nil, template: template, destination: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"), operation: operation)
                    }
                }
                .frame(height: 160)

                Picker("整理方式", selection: $operation) {
                    Text("复制").tag(CopyOrMove.copy)
                    Text("移动").tag(CopyOrMove.move)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                if let plan = viewModel.plan {
                    NavigationLink("预览 \(plan.operations.count) 项") {
                        PlanPreviewView(viewModel: viewModel)
                    }
                }

                if !taskList.tasks.isEmpty {
                    recentTasksSection
                }

                HStack {
                    Button("新建任务") { showTaskEditor = true }
                    Spacer()
                    Button("设置") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            }
            .padding()
            .frame(minWidth: 500, minHeight: 400)
            .sheet(isPresented: $showTaskEditor) {
                TaskEditorView(taskList: taskList)
            }
        }
        .onAppear {
            viewModel.settings = settings
            operation = settings.defaultOperation
            try? taskList.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .renamerPickFolders)) { notification in
            guard let urls = notification.object as? [URL] else { return }
            Task {
                let template = settings.defaultTemplate
                await viewModel.analyze(folders: urls, task: nil, template: template, destination: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"), operation: operation)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.errorMessage != nil || viewModel.successMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil; viewModel.successMessage = nil } }
        )) {
            Button("确定") {
                viewModel.errorMessage = nil
                viewModel.successMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? viewModel.successMessage ?? "")
        }
    }

    @ViewBuilder
    private var recentTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近任务")
                .font(.headline)
            ForEach(taskList.tasks) { task in
                Button {
                    Task {
                        if let template = settings.templates.first(where: { $0.id == task.templateID }) {
                            await viewModel.analyze(
                                folders: task.sourceFolders,
                                task: task,
                                template: template,
                                destination: task.destinationFolder,
                                operation: task.operation
                            )
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(task.name)
                                .font(.subheadline)
                            Text(task.sourceFolders.map(\.path).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "play.circle")
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DropZoneView: NSViewRepresentable {
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrop: onDrop)
    }

    @MainActor
    class Coordinator: NSObject, NSDraggingDestination {
        let onDrop: ([URL]) -> Void
        init(onDrop: @escaping ([URL]) -> Void) { self.onDrop = onDrop }

        func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            onDrop(urls)
            return true
        }
    }
}
