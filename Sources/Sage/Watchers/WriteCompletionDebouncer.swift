import Foundation

public protocol FileSizeReading: Sendable {
    func size(ofItemAt path: String) -> Int64?
}

public struct DefaultFileSizeReader: FileSizeReading {
    public init() {}
    public func size(ofItemAt path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}

/// 写入完成检测：文件大小在 stableWindow 内不变才认为写完。
public actor WriteCompletionDebouncer {
    private let stableWindow: TimeInterval
    private let pollInterval: TimeInterval
    private let sizeReader: any FileSizeReading
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(stableWindow: TimeInterval = 2.0, pollInterval: TimeInterval = 0.5,
                sizeReader: any FileSizeReading = DefaultFileSizeReader(),
                sleep: @escaping @Sendable (TimeInterval) async -> Void = {
                    try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.stableWindow = stableWindow
        self.pollInterval = pollInterval
        self.sizeReader = sizeReader
        self.sleep = sleep
    }

    public func waitUntilStable(path: String, timeout: TimeInterval = 60) async -> Bool {
        guard var lastSize = sizeReader.size(ofItemAt: path) else { return false }
        var stableFor: TimeInterval = 0
        var elapsed: TimeInterval = 0
        while elapsed < timeout {
            await sleep(pollInterval)
            elapsed += pollInterval
            guard let size = sizeReader.size(ofItemAt: path) else { return false }
            if size == lastSize {
                stableFor += pollInterval
                if stableFor >= stableWindow { return true }
            } else {
                stableFor = 0
                lastSize = size
            }
        }
        return false
    }
}
