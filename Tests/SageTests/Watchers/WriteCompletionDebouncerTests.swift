import XCTest
@testable import Sage

private final class ScriptedSizeReader: FileSizeReading, @unchecked Sendable {
    private var sizes: [Int64?]
    private var index = 0
    init(_ sizes: [Int64?]) { self.sizes = sizes }
    func size(ofItemAt path: String) -> Int64? {
        defer { index = min(index + 1, sizes.count - 1) }
        return sizes[index]
    }
}

final class WriteCompletionDebouncerTests: XCTestCase {
    private let instantSleep: @Sendable (TimeInterval) async -> Void = { _ in }

    func test大小稳定后返回true() async {
        // 100 → 200 → 200 → 200：稳定窗口 2s / 轮询 0.5s 需连续 4 次不变，这里给足
        let reader = ScriptedSizeReader([100, 200, 200, 200, 200, 200, 200])
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 100)
        XCTAssertTrue(ok)
    }

    func test文件消失返回false() async {
        let reader = ScriptedSizeReader([100, nil])
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 100)
        XCTAssertFalse(ok)
    }

    func test持续增长直到超时返回false() async {
        // 每次都变大，永不稳定；timeout 很小，很快返回 false
        let reader = GrowingSizeReader(step: 100)
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 2.0)
        XCTAssertFalse(ok)
    }
}

private final class GrowingSizeReader: FileSizeReading, @unchecked Sendable {
    private let step: Int64
    private var current: Int64 = 0
    private let lock = NSLock()
    init(step: Int64) { self.step = step }
    func size(ofItemAt path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        current += step
        return current
    }
}
