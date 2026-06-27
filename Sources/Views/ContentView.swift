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
                        let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .renamerPickFolders)) { notification in
            guard let urls = notification.object as? [URL] else { return }
            Task {
                let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
                await viewModel.analyze(folders: urls, task: nil, template: template, destination: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"), operation: operation)
            }
        }
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
