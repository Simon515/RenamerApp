import SwiftUI

struct ContentView: View {
    @State private var viewModel = MainViewModel()
    @State private var taskList = TaskListViewModel()
    @State private var showTaskEditor = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Renamer")
                .font(.largeTitle)
            DropZoneView { urls in
                Task {
                    let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
                    await viewModel.analyze(folders: urls, task: nil, template: template, destination: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"))
                }
            }
            .frame(height: 160)

            if let plan = viewModel.plan {
                NavigationLink("预览 \(plan.operations.count) 项") {
                    PlanPreviewView(viewModel: viewModel)
                }
            }

            HStack {
                Button("新建任务") { showTaskEditor = true }
                Spacer()
                Button("设置") { /* open settings */ }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showTaskEditor) {
            TaskEditorView(taskList: taskList)
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
