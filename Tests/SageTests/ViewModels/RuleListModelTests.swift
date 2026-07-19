import XCTest
@testable import Sage

@MainActor
final class RuleListModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageRuleList-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func rule(_ name: String) -> Rule {
        Rule(id: UUID(), name: name, enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [], actions: [.addFinderTags([name])], executionMode: .automatic)
    }

    func test加载与启停持久化() async throws {
        let store = RuleStore(directory: dir)
        let r = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [r]))
        let model = RuleListModel(store: store)
        await model.reload()
        XCTAssertEqual(model.rules.map(\.name), ["A"])
        await model.setEnabled(false, ruleID: r.id)
        XCTAssertFalse(model.rules[0].enabled)
        let reloaded = try await store.load()
        XCTAssertFalse(reloaded.rules[0].enabled)
    }

    func test复制插在原规则之后() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A"); let b = rule("B")
        try await store.save(RuleLibrary(version: 1, rules: [a, b]))
        let model = RuleListModel(store: store)
        await model.reload()
        await model.duplicate(ruleID: a.id)
        XCTAssertEqual(model.rules.count, 3)
        XCTAssertEqual(model.rules[1].name, "A 副本")
        XCTAssertNotEqual(model.rules[1].id, a.id)
        XCTAssertEqual(model.rules[2].name, "B")
    }

    func test删除与新增() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [a]))
        let model = RuleListModel(store: store)
        await model.reload()
        await model.delete(ruleID: a.id)
        XCTAssertTrue(model.rules.isEmpty)
        await model.add(rule("New"))
        XCTAssertEqual(model.rules.map(\.name), ["New"])
        let persisted = try await store.load().rules.map(\.name)
        XCTAssertEqual(persisted, ["New"])
    }

    func test导出JSON非空且可解码() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [a]))
        let model = RuleListModel(store: store)
        await model.reload()
        let json = model.exportJSON(ruleID: a.id)
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Rule.self, from: data)
        XCTAssertEqual(decoded.id, a.id)
    }
}
