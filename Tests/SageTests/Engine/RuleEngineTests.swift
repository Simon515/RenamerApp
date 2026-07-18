import XCTest
@testable import Sage

final class RuleEngineTests: XCTestCase {
    private let event = FileEvent(location: .local(path: "/in/发票2026.pdf"),
                                  source: .folderWatch(root: "/in"))

    private func makeRule(name: String = "R",
                          scopes: [RuleScope] = [.localFolder(path: "/in", recursive: false)],
                          trigger: TriggerMode = .automatic,
                          logic: ConditionLogic = .all,
                          conditions: [Condition],
                          actions: [Action] = [.moveTo(path: "/out")],
                          enabled: Bool = true) -> Rule {
        Rule(id: UUID(), name: name, enabled: enabled, scopes: scopes, trigger: trigger,
             conditionLogic: logic, conditions: conditions, actions: actions,
             executionMode: .automatic)
    }

    private func makeProvider() -> FakeFactsProvider {
        FakeFactsProvider(cheap: CheapFacts(name: "发票2026", fileExtension: "pdf", sizeBytes: 100))
    }

    func test命中生成计划() async {
        let engine = RuleEngine(provider: makeProvider())
        let rule = makeRule(conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(plan.planned.count, 1)
        XCTAssertEqual(plan.planned[0].ruleID, rule.id)
        XCTAssertEqual(plan.planned[0].actions, [.moveTo(path: "/out")])
    }

    func test首中即停() async {
        let engine = RuleEngine(provider: makeProvider())
        let first = makeRule(name: "第一", conditions: [.fileExtension(.equals("pdf"))])
        let second = makeRule(name: "第二", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [first, second])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["第一"])
    }

    func testContinueMatching放行后续规则() async {
        let engine = RuleEngine(provider: makeProvider())
        let first = makeRule(name: "第一", conditions: [.fileExtension(.equals("pdf"))],
                             actions: [.addFinderTags(["票据"]), .continueMatching])
        let second = makeRule(name: "第二", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [first, second])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["第一", "第二"])
    }

    func test跳过禁用与作用域外与仅手动() async {
        let engine = RuleEngine(provider: makeProvider())
        let disabled = makeRule(name: "禁用", conditions: [], enabled: false)
        let outOfScope = makeRule(name: "别处",
                                  scopes: [.localFolder(path: "/elsewhere", recursive: true)],
                                  conditions: [])
        let manualOnly = makeRule(name: "仅手动", trigger: .manualOnly, conditions: [])
        let plan = await engine.plan(for: event, rules: [disabled, outOfScope, manualOnly])
        XCTAssertTrue(plan.planned.isEmpty)
    }

    func testAll短路_零成本失败不触发LLM() async {
        let provider = makeProvider()
        let engine = RuleEngine(provider: provider)
        let rule = makeRule(logic: .all, conditions: [
            .contentBelongsTo(category: "发票", minConfidence: 0.7), // LLM 档，写在前面
            .fileExtension(.equals("jpg")),                          // 零成本，会失败
        ])
        _ = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(provider.llmCalls, 0, "零成本条件失败后不应调用 LLM")
    }

    func testAny短路_零成本命中不触发LLM() async {
        let provider = makeProvider()
        let engine = RuleEngine(provider: provider)
        let rule = makeRule(logic: .any, conditions: [
            .contentBelongsTo(category: "发票", minConfidence: 0.7),
            .fileExtension(.equals("pdf")), // 零成本，会命中
        ])
        let plan = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(plan.planned.count, 1)
        XCTAssertEqual(provider.llmCalls, 0)
    }

    func test求值抛错的规则视为不匹配且不阻塞后续() async {
        final class ThrowingProvider: FactsProvider, @unchecked Sendable {
            func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
                CheapFacts(name: "发票2026", fileExtension: "pdf", sizeBytes: 1)
            }
            func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
                struct Boom: Error {}
                throw Boom()
            }
            func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
                SemanticVerdict(matches: false, confidence: 0)
            }
            func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
                SemanticVerdict(matches: false, confidence: 0)
            }
        }
        let engine = RuleEngine(provider: ThrowingProvider())
        let broken = makeRule(name: "会抛错", conditions: [.textContent(.contains("税号"))])
        let healthy = makeRule(name: "健康", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [broken, healthy])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["健康"])
    }
}
