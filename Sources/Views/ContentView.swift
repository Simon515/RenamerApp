import SwiftUI

struct ContentView: View {
    @Environment(SettingsViewModel.self) private var settings
    @State private var viewModel = MainViewModel()
    @State private var taskList = TaskListViewModel()
    @State private var showTaskEditor = false
    @State private var showHistory = false
    @State private var operation: CopyOrMove = .copy

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Renamer")
                    .font(.largeTitle)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.secondary)
                    .frame(height: 160)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("拖拽文件夹到此处开始分析")
                                .foregroundStyle(.secondary)
                            Button("或点击选择文件夹…") { pickFolders() }
                                .buttonStyle(.link)
                        }
                    }
                    .overlay {
                        DropZoneView { urls in analyze(folders: urls) }
                    }

                Text("目标目录：\(settings.quickDestination.path())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Picker("整理方式", selection: $operation) {
                    Text("复制").tag(CopyOrMove.copy)
                    Text("移动").tag(CopyOrMove.move)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .disabled(viewModel.isAnalyzing)

                if viewModel.isAnalyzing, let progress = viewModel.progress {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(progress.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("取消") { viewModel.cancelAnalysis() }
                            .buttonStyle(.link)
                    }
                }

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
                    Button("历史记录") { showHistory = true }
                }
            }
            .padding()
            .frame(minWidth: 500, minHeight: 400)
            .sheet(isPresented: $showTaskEditor) {
                TaskEditorView(taskList: taskList)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
        }
        .onAppear {
            viewModel.settings = settings
            operation = settings.defaultOperation
            try? taskList.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .renamerPickFolders)) { notification in
            guard let urls = notification.object as? [URL] else { return }
            analyze(folders: urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: .renamerRunTask)) { notification in
            guard let taskID = notification.object as? UUID,
                  let task = taskList.tasks.first(where: { $0.id == taskID }),
                  let template = settings.templates.first(where: { $0.id == task.templateID }) else { return }
            viewModel.analyze(
                folders: task.sourceFolders,
                task: task,
                template: template,
                destination: task.destinationFolder,
                operation: task.operation
            )
        }
        .userMessageAlert($viewModel.userMessage)
    }

    /// 分析所选文件夹，复用主窗口默认模板与目标目录。
    private func analyze(folders: [URL]) {
        guard !folders.isEmpty else { return }
        let template = settings.defaultTemplate
        let destination = settings.quickDestination
        viewModel.analyze(folders: folders, task: nil, template: template, destination: destination, operation: operation)
    }

    /// 通过 NSOpenPanel 选择文件夹，作为拖拽之外的备用入口。
    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            analyze(folders: panel.urls)
        }
    }

    @ViewBuilder
    private var recentTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近任务")
                .font(.headline)
            ForEach(taskList.tasks) { task in
                Button {
                    if let template = settings.templates.first(where: { $0.id == task.templateID }) {
                        viewModel.analyze(
                            folders: task.sourceFolders,
                            task: task,
                            template: template,
                            destination: task.destinationFolder,
                            operation: task.operation
                        )
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

/// 文件夹拖放接收视图。
///
/// 直接使用自定义 `NSView` 子类重写拖放回调——`NSView` 自身即拖放目标，
/// 不存在独立的 delegate，因此必须在视图内重写 `draggingEntered`/`performDragOperation`。
struct DropZoneView: NSViewRepresentable {
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FolderDropNSView {
        let view = FolderDropNSView()
        view.onDrop = onDrop
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: FolderDropNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

final class FolderDropNSView: NSView {
    var onDrop: (([URL]) -> Void)?

    /// 仅接受指向目录的文件 URL。
    private func folderURLs(from sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folderURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let folders = folderURLs(from: sender)
        guard !folders.isEmpty else { return false }
        onDrop?(folders)
        return true
    }
}
