import Foundation
import CoreServices

/// 监控源统一抽象。
public protocol FileEventSource: AnyObject, Sendable {
    func start()
    func stop()
}

/// 本地文件夹监控（FSEvents）。FSEvents 接线薄，可测逻辑集中在 classify。
public final class FolderWatcher: FileEventSource, @unchecked Sendable {
    /// FSEvents 事件标志的精简镜像（便于纯逻辑测试）。
    public struct EventFlag: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let isFile = EventFlag(rawValue: 1 << 0)
        public static let isDir = EventFlag(rawValue: 1 << 1)
        public static let removed = EventFlag(rawValue: 1 << 2)
        public static let renamed = EventFlag(rawValue: 1 << 3)
    }

    private let roots: [String]
    private let recursive: Bool
    private let debouncer: WriteCompletionDebouncer
    private let onEvent: @Sendable (FileEvent) async -> Void
    private var stream: FSEventStreamRef?

    public init(roots: [String], recursive: Bool,
                debouncer: WriteCompletionDebouncer = WriteCompletionDebouncer(),
                onEvent: @escaping @Sendable (FileEvent) async -> Void) {
        self.roots = roots
        self.recursive = recursive
        self.debouncer = debouncer
        self.onEvent = onEvent
    }

    /// 把 FSEvents 回调的路径+标志翻译为需处理的文件路径（过滤目录/删除/隐藏）。
    public static func classify(paths: [String], flags: [EventFlag]) -> [String] {
        zip(paths, flags).compactMap { path, flag in
            guard flag.contains(.isFile) else { return nil }
            guard !flag.contains(.removed) else { return nil }
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            return path
        }
    }

    public func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathPtr = unsafeBitCast(paths, to: NSArray.self)
            var pathList: [String] = []
            var flagList: [EventFlag] = []
            for i in 0..<count {
                pathList.append((pathPtr[i] as? String) ?? "")
                flagList.append(watcher.translate(flags[i]))
            }
            let files = FolderWatcher.classify(paths: pathList, flags: flagList)
            let root = watcher.roots.first ?? ""
            for file in files {
                Task { [debouncer = watcher.debouncer, onEvent = watcher.onEvent] in
                    if await debouncer.waitUntilStable(path: file) {
                        await onEvent(FileEvent(location: .local(path: file), source: .folderWatch(root: root)))
                    }
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.5, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.jiyuliang.Sage.fsevents"))
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func translate(_ raw: FSEventStreamEventFlags) -> EventFlag {
        var flag: EventFlag = []
        if raw & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 { flag.insert(.isFile) }
        if raw & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { flag.insert(.isDir) }
        if raw & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { flag.insert(.removed) }
        if raw & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { flag.insert(.renamed) }
        return flag
    }
}
