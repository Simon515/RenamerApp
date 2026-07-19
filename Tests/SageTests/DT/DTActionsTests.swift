import XCTest
@testable import Sage

/// 记录收到的脚本并按序返回预设结果。
private final class FakeRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String]
    private var recorded: [String] = []
    init(results: [String]) { self.results = results }
    func run(_ source: String) async throws -> String { record(source) }
    private func record(_ source: String) -> String {
        lock.lock(); defer { lock.unlock() }
        recorded.append(source)
        return results.isEmpty ? "" : results.removeFirst()
    }
    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

final class DTActionsTests: XCTestCase {
    private let dtLoc = FileLocation.devonthink(uuid: "U", database: "D", groupPath: "/g")

    func test导入返回uuid并产出可逆操作() async throws {
        let runner = FakeRunner(results: ["UUID-42"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(
            .dtImport(database: "D", groupPath: "/g", tags: ["t"], noteTemplate: "备注"),
            at: .local(path: "/tmp/a.pdf"))
        XCTAssertEqual(ops, [.dtImported(uuid: "UUID-42", database: "D")])
        XCTAssertTrue(runner.scripts[0].contains(#"import "/tmp/a.pdf""#))
    }

    func test导入需要本地来源() async {
        let dt = DTActions(runner: FakeRunner(results: []), isRunning: { true })
        do {
            _ = try await dt.execute(.dtImport(database: "D", groupPath: "/g", tags: [], noteTemplate: nil),
                                     at: dtLoc)
            XCTFail("应当抛错")
        } catch { XCTAssertEqual(error as? DTError, .needsLocalFile) }
    }

    func testDT内改名记录旧名() async throws {
        let runner = FakeRunner(results: ["旧名"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtRename(template: "新名"), at: dtLoc)
        XCTAssertEqual(ops, [.dtRenamed(uuid: "U", from: "旧名", to: "新名")])
    }

    func testDT加标签记录旧标签() async throws {
        let runner = FakeRunner(results: ["a\nb"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtAddTags(["c"]), at: dtLoc)
        XCTAssertEqual(ops, [.dtAddedTags(["c"], uuid: "U", previous: ["a", "b"])])
    }

    func testDT移动记录旧位置() async throws {
        let runner = FakeRunner(results: ["D1\t/inbox"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtMoveToGroup(database: "D2", groupPath: "/done"),
                                       at: .devonthink(uuid: "U", database: "D1", groupPath: "/inbox"))
        XCTAssertEqual(ops, [.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/inbox",
                                      toDatabase: "D2", toGroup: "/done")])
    }

    func testDT未运行抛notRunning() async {
        let dt = DTActions(runner: FakeRunner(results: []), isRunning: { false })
        do {
            _ = try await dt.execute(.dtAddTags(["x"]), at: dtLoc)
            XCTFail("应当抛错")
        } catch { XCTAssertEqual(error as? DTError, .notRunning) }
    }

    func test回滚导入即删除记录() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtImported(uuid: "U", database: "D"))
        XCTAssertTrue(runner.scripts[0].contains(#"delete record (get record with uuid "U")"#))
    }

    func test回滚改名恢复旧名() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtRenamed(uuid: "U", from: "旧", to: "新"))
        XCTAssertTrue(runner.scripts[0].contains(#"set name of (get record with uuid "U") to "旧""#))
    }

    func test回滚标签恢复previous() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtAddedTags(["c"], uuid: "U", previous: ["a"]))
        XCTAssertTrue(runner.scripts[0].contains(#"set tags of (get record with uuid "U") to {"a"}"#))
    }

    func test回滚移动搬回原组() async throws {
        let runner = FakeRunner(results: ["D2\t/done"])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/inbox",
                                     toDatabase: "D2", toGroup: "/done"))
        XCTAssertTrue(runner.scripts[0].contains(#"get record at "/inbox" in database "D1""#))
    }

    // MARK: - LocalActionExecutor 路由集成

    func test本地导入后续DT动作作用于新记录() async throws {
        let runner = FakeRunner(results: ["NEW-UUID", "旧名"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let executor = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: ExtractedMetadata()),
                                           dtExecutor: dt)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dtchain-\(UUID()).pdf")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ops = try await executor.run(
            actions: [.dtImport(database: "D", groupPath: "/g", tags: [], noteTemplate: nil),
                      .dtRename(template: "新名")],
            on: .local(path: tmp.path))
        XCTAssertEqual(ops, [.dtImported(uuid: "NEW-UUID", database: "D"),
                             .dtRenamed(uuid: "NEW-UUID", from: "旧名", to: "新名")])
        XCTAssertTrue(runner.scripts[1].contains(#"uuid "NEW-UUID""#))
    }

    func testDT位置事件的本地动作被拒绝() async {
        let executor = LocalActionExecutor(
            metadataProvider: FakeMetadataProvider(result: ExtractedMetadata()),
            dtExecutor: DTActions(runner: FakeRunner(results: []), isRunning: { true }))
        do {
            _ = try await executor.run(actions: [.rename(template: "x")], on: dtLoc)
            XCTFail("应当抛错")
        } catch {
            // notLocalFile（或包装后的等价错误）即可
        }
    }

    func testDT位置事件的DT动作直接分派() async throws {
        let runner = FakeRunner(results: ["a\nb"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let executor = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: ExtractedMetadata()),
                                           dtExecutor: dt)
        let ops = try await executor.run(actions: [.dtAddTags(["c"])], on: dtLoc)
        XCTAssertEqual(ops, [.dtAddedTags(["c"], uuid: "U", previous: ["a", "b"])])
    }

    func test导入备注模板令牌解析() async throws {
        let runner = FakeRunner(results: ["UUID-1"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let meta = ExtractedMetadata(title: "标题", summary: "这是摘要")
        let executor = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: meta),
                                           dtExecutor: dt)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dtnote-\(UUID()).pdf")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await executor.run(
            actions: [.llmExtractMetadata,
                      .dtImport(database: "D", groupPath: "/g", tags: [], noteTemplate: "{summary}")],
            on: .local(path: tmp.path))
        XCTAssertTrue(runner.scripts[0].contains("这是摘要"))
        XCTAssertFalse(runner.scripts[0].contains("{summary}"))
    }
}
