import Foundation

/// 本地文件系统动作执行器（actor：写操作串行）。
public actor LocalActionExecutor {
    private let metadataProvider: any MetadataProviding
    private let pathResolver: TargetPathResolver
    private let fileManager: FileManager
    private let dtExecutor: any DTActionExecutor

    public init(metadataProvider: any MetadataProviding,
                pathResolver: TargetPathResolver = TargetPathResolver(),
                fileManager: FileManager = .default,
                dtExecutor: any DTActionExecutor = UnimplementedDTActionExecutor()) {
        self.metadataProvider = metadataProvider
        self.pathResolver = pathResolver
        self.fileManager = fileManager
        self.dtExecutor = dtExecutor
    }

    public func run(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp] {
        try await execute(actions: actions, on: startLocation, allowTrash: false)
    }

    public func runIncludingTrash(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp] {
        try await execute(actions: actions, on: startLocation, allowTrash: true)
    }

    private func execute(actions: [Action], on startLocation: FileLocation,
                         allowTrash: Bool) async throws -> [ReversibleOp] {
        guard case .local(var currentPath) = startLocation else { throw ActionExecutionError.notLocalFile }
        var ops: [ReversibleOp] = []
        var metadata = ExtractedMetadata()

        for action in actions {
            do {
                switch action {
                case .continueMatching:
                    continue
                case .llmExtractMetadata:
                    metadata = try await metadataProvider.metadata(for: .local(path: currentPath))
                case .moveTo(let destDir):
                    let name = (currentPath as NSString).lastPathComponent
                    let dest = dedupInDir(destDir, name: name)
                    try move(from: currentPath, to: dest)
                    ops.append(.moved(from: currentPath, to: dest))
                    currentPath = dest
                case .copyTo(let destDir):
                    let name = (currentPath as NSString).lastPathComponent
                    let dest = dedupInDir(destDir, name: name)
                    try fileManager.copyItem(atPath: currentPath, toPath: dest)
                    ops.append(.copied(to: dest))
                case .rename(let template):
                    let dest = pathResolver.resolveRename(inDirectoryOf: currentPath, template: template, metadata: metadata)
                    try move(from: currentPath, to: dest)
                    ops.append(.renamed(from: currentPath, to: dest))
                    currentPath = dest
                case .llmRename(let instruction):
                    let dest = pathResolver.resolveRename(inDirectoryOf: currentPath, template: instruction, metadata: metadata)
                    try move(from: currentPath, to: dest)
                    ops.append(.renamed(from: currentPath, to: dest))
                    currentPath = dest
                case .addFinderTags(let tags):
                    let op = try addFinderTags(tags, to: currentPath)
                    ops.append(op)
                case .moveToTrash:
                    guard allowTrash else { throw ActionExecutionError.unsupportedAction("移到废纸篓（需经确认队列）") }
                    let op = try trash(currentPath)
                    ops.append(op)
                    return ops // 文件已入废纸篓，后续动作无意义
                case .dtImport, .dtRename, .dtAddTags, .dtMoveToGroup:
                    let dtOps = try await dtExecutor.execute(action, at: .local(path: currentPath))
                    ops.append(contentsOf: dtOps)
                }
            } catch {
                // 若已有成功完成的可逆操作，包装为 PartialActionFailure 以便上层记入 Journal；
                // 否则（尚未产生任何操作）原样抛出，保留即时失败的既有行为。
                if ops.isEmpty { throw error }
                throw PartialActionFailure(completedOps: ops, underlying: error)
            }
        }
        return ops
    }

    private func move(from: String, to: String) throws {
        guard fileManager.fileExists(atPath: from) else { throw ActionExecutionError.sourceMissing(from) }
        try fileManager.moveItem(atPath: from, toPath: to)
    }

    private func dedupInDir(_ dir: String, name: String) -> String {
        let full = (dir as NSString).appendingPathComponent(name)
        guard fileManager.fileExists(atPath: full) else { return full }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    private func addFinderTags(_ tags: [String], to path: String) throws -> ReversibleOp {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey])
            let previous = values.tagNames ?? []
            let merged = Array(Set(previous).union(tags)).sorted()
            try writeFinderTags(merged, to: path)
            return .addedFinderTags(merged, to: path, previous: previous)
        } catch let error as ActionExecutionError {
            throw error
        } catch {
            throw ActionExecutionError.finderTagsFailed(error.localizedDescription)
        }
    }

    /// 通过扩展属性写回 Finder 标签（`URLResourceValues.tagNames` 的 setter 在 macOS 26 之前不可用，
    /// 故直接写 `com.apple.metadata:_kMDItemUserTags`，兼容 macOS 14+）。
    private func writeFinderTags(_ tags: [String], to path: String) throws {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, data.count, 0, 0)
        }
        if result != 0 {
            throw ActionExecutionError.finderTagsFailed(String(cString: strerror(errno)))
        }
    }

    private func trash(_ path: String) throws -> ReversibleOp {
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return .trashed(originalPath: path, trashPath: resulting?.path)
    }
}
