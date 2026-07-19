import XCTest
@testable import Sage

@MainActor
final class ConfirmQueueModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageQueueVM-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // 组装一个真实 Coordinator（确认规则：pdf → 移到废纸篓）
    private func makeStack() async throws -> (ConfirmQueueModel, Coordinator, ConfirmQueue) {
        let engine = RuleEngine(provider: FakeFactsProvider(cheap: CheapFacts(name: "a", fileExtension: "pdf", sizeBytes: 1)))
        let rule = Rule(id: UUID(), name: "删除", enabled: true,
                        scopes: [.localFolder(path: dir.path, recursive: true)], trigger: .automatic,
                        conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
                        actions: [.moveToTrash], executionMode: .confirmFirst)
        let store = RuleStore(directory: dir)
        try await store.save(RuleLibrary(version: 1, rules: [rule]))
        let queue = ConfirmQueue(directory: dir)
        let coordinator = Coordinator(
            engine: engine, rulesProvider: RuleStoreRulesProvider(store: store),
            executor: LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init())),
            journal: Journal(directory: dir), confirmQueue: queue)
        return (ConfirmQueueModel(queue: queue, coordinator: coordinator), coordinator, queue)
    }

    func test加载与批准出队执行() async throws {
        let src = try makeFile("a.pdf")
        let (model, coordinator, queue) = try await makeStack()
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        XCTAssertEqual(model.items.count, 1)
        let id = model.items[0].id
        await model.approve(id: id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src)) // 已删
        let count = try await queue.count()
        XCTAssertEqual(count, 0)
    }

    func test拒绝出队不执行() async throws {
        let src = try makeFile("b.pdf")
        let (model, coordinator, _) = try await makeStack()
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        await model.reject(id: model.items[0].id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src)) // 未删
    }

    func test批准失败保留错误消息() async throws {
        let src = try makeFile("d.pdf")
        let (model, coordinator, _) = try await makeStack()
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        // 入队后删掉底层文件，使批准执行失败
        try FileManager.default.removeItem(atPath: src)
        await model.approve(id: model.items[0].id)
        // 失败信息不应被随后的 reload 抹掉
        XCTAssertNotNil(model.errorMessage)
    }

    func test摘要非空() async throws {
        let src = try makeFile("c.pdf")
        let (model, coordinator, _) = try await makeStack()
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        let s = ConfirmQueueModel.summary(model.items[0])
        XCTAssertTrue(s.contains("废纸篓"))
    }
}
