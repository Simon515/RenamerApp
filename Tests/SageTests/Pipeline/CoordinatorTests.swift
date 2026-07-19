import XCTest
@testable import Sage

private struct FixedRules: RulesProviding {
    let rules: [Rule]
    func currentRules() async -> [Rule] { rules }
}

final class CoordinatorTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageCoord-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func rule(name: String, conditions: [Condition], actions: [Action],
                      mode: ExecutionMode) -> Rule {
        Rule(id: UUID(), name: name, enabled: true,
             scopes: [.localFolder(path: dir.path, recursive: true)],
             trigger: .automatic, conditionLogic: .all,
             conditions: conditions, actions: actions, executionMode: mode)
    }

    private func makeCoordinator(rules: [Rule]) -> Coordinator {
        let engine = RuleEngine(provider: FakeFactsProvider(
            cheap: CheapFacts(name: "a", fileExtension: "pdf", sizeBytes: 1)))
        return Coordinator(engine: engine, rulesProvider: FixedRules(rules: rules),
                           executor: LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init())),
                           journal: Journal(directory: dir), confirmQueue: ConfirmQueue(directory: dir))
    }

    func test自动规则_执行并写日志() async throws {
        let src = try makeFile("a.pdf")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let coord = makeCoordinator(rules: [
            rule(name: "移动", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveTo(path: outDir.path)], mode: .automatic)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .folderWatch(root: dir.path)))
        if case .executed = outcomes.first {} else { XCTFail("应 executed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
        // 日志有一条
        let journal = Journal(directory: dir)
        let count = try await journal.all().count
        XCTAssertEqual(count, 1)
    }

    func test自动规则_中途失败仍写部分执行日志() async throws {
        let src = try makeFile("a.pdf")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let missingDir = dir.appendingPathComponent("nope") // 不创建，copy 会失败
        let coord = makeCoordinator(rules: [
            rule(name: "移动后复制", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveTo(path: outDir.path), .copyTo(path: missingDir.path)], mode: .automatic)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .folderWatch(root: dir.path)))
        if case .failed = outcomes.first {} else { XCTFail("应 failed") }
        // 部分执行（move）必须记入日志以便回滚
        let journal = Journal(directory: dir)
        let records = try await journal.all()
        XCTAssertEqual(records.count, 1)
        let movedDest = outDir.appendingPathComponent("a.pdf").path
        XCTAssertTrue(records.first!.ops.contains(.moved(from: src, to: movedDest)))
    }

    func test确认模式_入队不执行() async throws {
        let src = try makeFile("a.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        if case .enqueued = outcomes.first {} else { XCTFail("应 enqueued") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src)) // 未删
        let count = try await ConfirmQueue(directory: dir).count()
        XCTAssertEqual(count, 1)
    }

    func test无匹配规则_skipped() async throws {
        let src = try makeFile("a.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "只匹配jpg", conditions: [.fileExtension(.equals("jpg"))],
                 actions: [.moveTo(path: "/out")], mode: .automatic)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        if case .skipped = outcomes.first {} else { XCTFail("应 skipped") }
    }

    func test批准队列项_执行删除并出队() async throws {
        let src = try makeFile("del.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        _ = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        let queue = ConfirmQueue(directory: dir)
        let pending = try await queue.all().first!
        let outcome = await coord.approve(pendingID: pending.id)
        if case .executed = outcome {} else { XCTFail("应 executed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: src)) // 已删
        let count = try await queue.count()
        XCTAssertEqual(count, 0)
    }

    func test拒绝队列项_出队不执行() async throws {
        let src = try makeFile("keep.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        _ = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        let queue = ConfirmQueue(directory: dir)
        let pending = try await queue.all().first!
        try await coord.reject(pendingID: pending.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        let count = try await queue.count()
        XCTAssertEqual(count, 0)
    }
}
