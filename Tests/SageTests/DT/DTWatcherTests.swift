import XCTest
@testable import Sage

/// 每次调用按序返回下一轮结果。
private final class SequenceRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [String]
    init(rounds: [String]) { self.rounds = rounds }
    func run(_ source: String) async throws -> String { next() }
    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return rounds.isEmpty ? "" : rounds.removeFirst()
    }
}

private actor EventSink {
    var events: [FileEvent] = []
    func add(_ e: FileEvent) { events.append(e) }
    func all() -> [FileEvent] { events }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); defer { lock.unlock() }; value = v }
}

private final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func append(_ v: T) { lock.lock(); defer { lock.unlock() }; items.append(v) }
    func all() -> [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class DTWatcherTests: XCTestCase {
    private let g = DTWatchedGroup(database: "D", groupPath: "/inbox")

    func test首轮建基线不发事件_新条目次轮发事件() async throws {
        let runner = SequenceRunner(rounds: [
            "U1\t2026-07-01T00:00:00\n",                          // 第 1 轮：基线
            "U1\t2026-07-01T00:00:00\nU2\t2026-07-02T00:00:00\n", // 第 2 轮：新增 U2
        ])
        let sink = EventSink()
        let watcher = DTWatcher(groups: [g], runner: runner, isRunning: { true },
                                onEvent: { await sink.add($0) })
        await watcher.pollOnce()
        await watcher.pollOnce()
        let events = await sink.all()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].location, .devonthink(uuid: "U2", database: "D", groupPath: "/inbox"))
        XCTAssertEqual(events[0].source, .dtWatch(database: "D", groupPath: "/inbox"))
    }

    func test修改时间变化视为新事件() async throws {
        let runner = SequenceRunner(rounds: ["U1\tt1\n", "U1\tt2\n"])
        let sink = EventSink()
        let watcher = DTWatcher(groups: [g], runner: runner, isRunning: { true },
                                onEvent: { await sink.add($0) })
        await watcher.pollOnce()
        await watcher.pollOnce()
        let events = await sink.all()
        XCTAssertEqual(events.count, 1)
    }

    func test无变化不发事件() async throws {
        let runner = SequenceRunner(rounds: ["U1\tt1\n", "U1\tt1\n"])
        let sink = EventSink()
        let watcher = DTWatcher(groups: [g], runner: runner, isRunning: { true },
                                onEvent: { await sink.add($0) })
        await watcher.pollOnce()
        await watcher.pollOnce()
        let events = await sink.all()
        XCTAssertTrue(events.isEmpty)
    }

    func testDT未运行跳过轮询且状态回调仅变化时触发() async throws {
        let flag = LockedBox(false)
        let statuses = LockedArray<Bool>()
        let watcher = DTWatcher(groups: [g], runner: SequenceRunner(rounds: []),
                                isRunning: { flag.get() },
                                onEvent: { _ in },
                                onAvailabilityChange: { statuses.append($0) })
        await watcher.pollOnce()   // 未运行 → false
        await watcher.pollOnce()   // 仍未运行 → 不重复回调
        flag.set(true)
        await watcher.pollOnce()   // 恢复 → true
        XCTAssertEqual(statuses.all(), [false, true])
    }

    func test脚本失败该轮跳过不中断() async throws {
        // runner 抛错：pollOnce 不应向外抛
        struct FailingRunner: AppleScriptRunning {
            func run(_ source: String) async throws -> String { throw DTError.scriptFailed("x") }
        }
        let watcher = DTWatcher(groups: [g], runner: FailingRunner(), isRunning: { true },
                                onEvent: { _ in })
        await watcher.pollOnce() // 不崩溃即可
    }

    func test从规则推导去重DT组() {
        let r1 = Rule(id: UUID(), name: "a", enabled: true,
                      scopes: [.devonthink(database: "D", groupPath: "/x")], trigger: .automatic,
                      conditionLogic: .all, conditions: [], actions: [.dtAddTags(["t"])], executionMode: .automatic)
        var r2 = r1; r2.id = UUID(); r2.trigger = .manualOnly       // 手动规则不监控
        var r3 = r1; r3.id = UUID(); r3.enabled = false             // 停用不监控
        var r4 = r1; r4.id = UUID()                                 // 同组去重
        let groups = DTWatcher.watchedGroups(rules: [r1, r2, r3, r4])
        XCTAssertEqual(groups, [DTWatchedGroup(database: "D", groupPath: "/x")])
    }
}
