import XCTest
@testable import Sage

final class WatcherSupervisorDTTests: XCTestCase {
    func testDT规则触发DTWatcher启动与停止不崩溃() async throws {
        // 冒烟：带 DT 作用域的规则 restart/stopAll 生命周期正常
        // （isRunning=false → DTWatcher 跳过轮询，runner 永不被真实调用）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageWS-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        let core = SageCore.makeDefault(supportDirectory: dir, gateway: gateway)
        let supervisor = WatcherSupervisor(coordinator: core.coordinator, dtIsRunning: { false })
        let rule = Rule(id: UUID(), name: "dt", enabled: true,
                        scopes: [.devonthink(database: "D", groupPath: "/g")], trigger: .automatic,
                        conditionLogic: .all, conditions: [], actions: [.dtAddTags(["t"])],
                        executionMode: .automatic)
        await supervisor.restart(rules: [rule])
        await supervisor.stopAll()
    }

    func testDT可用性回调经handler传递() async throws {
        // isRunning=false 首轮 pollOnce 即回调 false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageWS2-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        let core = SageCore.makeDefault(supportDirectory: dir, gateway: gateway)
        let supervisor = WatcherSupervisor(coordinator: core.coordinator, dtIsRunning: { false })
        let exp = expectation(description: "availability callback")
        await supervisor.setDTAvailabilityHandler { available in
            if !available { exp.fulfill() }
        }
        let rule = Rule(id: UUID(), name: "dt", enabled: true,
                        scopes: [.devonthink(database: "D", groupPath: "/g")], trigger: .automatic,
                        conditionLogic: .all, conditions: [], actions: [.dtAddTags(["t"])],
                        executionMode: .automatic)
        await supervisor.restart(rules: [rule])
        await fulfillment(of: [exp], timeout: 3)
        await supervisor.stopAll()
    }
}
