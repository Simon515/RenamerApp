import XCTest
@testable import Sage

final class RuleTests: XCTestCase {
    private func makeRule(conditions: [Condition] = [.fileExtension(.equals("pdf"))],
                          actions: [Action] = [.moveTo(path: "/tmp/out")],
                          executionMode: ExecutionMode = .automatic) -> Rule {
        Rule(id: UUID(), name: "测试规则", enabled: true,
             scopes: [.localFolder(path: "/tmp/in", recursive: false)],
             trigger: .automatic, conditionLogic: .all,
             conditions: conditions, actions: actions, executionMode: executionMode)
    }

    func testUsesLLM_条件含LLM档() {
        let rule = makeRule(conditions: [.contentBelongsTo(category: "发票", minConfidence: 0.7)])
        XCTAssertTrue(rule.usesLLM)
    }

    func testUsesLLM_动作含LLM() {
        XCTAssertTrue(makeRule(actions: [.llmRename(instruction: "按标题命名")]).usesLLM)
        XCTAssertFalse(makeRule().usesLLM)
    }

    func testRequiresConfirmation_废纸篓动作强制() {
        let rule = makeRule(actions: [.moveToTrash], executionMode: .automatic)
        XCTAssertTrue(rule.requiresConfirmation)
    }

    func testRequiresConfirmation_跟随执行模式() {
        XCTAssertTrue(makeRule(executionMode: .confirmFirst).requiresConfirmation)
        XCTAssertFalse(makeRule(executionMode: .automatic).requiresConfirmation)
    }

    func testCodable_往返() throws {
        let rule = makeRule()
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(Rule.self, from: data), rule)
    }
}
