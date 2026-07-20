import XCTest
@testable import Sage

final class WatcherSupervisorTests: XCTestCase {
    private func rule(name: String, enabled: Bool, trigger: TriggerMode, scopes: [RuleScope]) -> Rule {
        Rule(id: UUID(), name: name, enabled: enabled, scopes: scopes, trigger: trigger,
             conditionLogic: .all, conditions: [], actions: [.addFinderTags(["x"])], executionMode: .automatic)
    }

    func test收集去重监控根() {
        let rules = [
            rule(name: "A", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/in", recursive: false)]),
            rule(name: "B", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/in", recursive: true)]),
            rule(name: "C", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/other", recursive: false)]),
        ]
        let roots = WatcherSupervisor.watchedRoots(rules: rules)
        // /in 合并为 recursive=true；/other 保持 false
        XCTAssertEqual(Set(roots), Set([
            WatchedRoot(path: "/in", recursive: true),
            WatchedRoot(path: "/other", recursive: false),
        ]))
    }

    func test跳过禁用与仅手动规则() {
        let rules = [
            rule(name: "disabled", enabled: false, trigger: .automatic, scopes: [.localFolder(path: "/a", recursive: true)]),
            rule(name: "manual", enabled: true, trigger: .manualOnly, scopes: [.localFolder(path: "/b", recursive: true)]),
            rule(name: "dtonly", enabled: true, trigger: .automatic, scopes: [.devonthink(database: "D", groupPath: "/G")]),
        ]
        XCTAssertTrue(WatcherSupervisor.watchedRoots(rules: rules).isEmpty)
    }
}
