import XCTest
@testable import Sage

@MainActor
final class RuleEditorModelTests: XCTestCase {
    private func engine(ext: String) -> RuleEngine {
        RuleEngine(provider: FakeFactsProvider(cheap: CheapFacts(name: "a", fileExtension: ext, sizeBytes: 10)))
    }

    private func baseRule() -> Rule {
        Rule(id: UUID(), name: "R", enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
             actions: [.moveTo(path: "/out")], executionMode: .automatic)
    }

    func test试运行匹配() async {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        await model.performDryRun(samplePath: "/in/a.pdf")
        XCTAssertEqual(model.dryRun?.matched, true)
        XCTAssertEqual(model.dryRun?.resolvedActions.first, "移动到 /out")
    }

    func test试运行不匹配() async {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "jpg"))
        await model.performDryRun(samplePath: "/in/a.jpg")
        XCTAssertEqual(model.dryRun?.matched, false)
    }

    func test增删条件与动作() {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        model.addAction(.addFinderTags(["x"]))
        XCTAssertEqual(model.draft.actions.count, 2)
        model.removeAction(at: 0)
        XCTAssertEqual(model.draft.actions.count, 1)
        model.addCondition(.name(.contains("发票")))
        XCTAssertEqual(model.draft.conditions.count, 2)
        model.removeCondition(at: 1)
        XCTAssertEqual(model.draft.conditions.count, 1)
    }

    func test校验() {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        XCTAssertTrue(model.isValid)
        model.draft.name = ""
        XCTAssertFalse(model.isValid)
        model.draft.name = "R"
        model.draft.actions = []
        XCTAssertFalse(model.isValid)
    }

    func test动作描述() {
        XCTAssertEqual(RuleEditorModel.describe(.rename(template: "{title}")), "重命名为 {title}")
        XCTAssertEqual(RuleEditorModel.describe(.moveToTrash), "移到废纸篓")
        XCTAssertEqual(RuleEditorModel.describe(.llmExtractMetadata), "用 LLM 提取元数据")
    }
}
