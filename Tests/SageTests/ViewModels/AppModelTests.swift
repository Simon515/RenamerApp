import XCTest
@testable import Sage

@MainActor
final class AppModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageApp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> AppModel {
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        return AppModel(supportDirectory: dir, settings: .defaults, gateway: gateway, keychain: SageKeychainStore())
    }

    func test手动拖入触发自动规则并进活动() async throws {
        // 规则：pdf → 移动到 out
        let inDir = dir.appendingPathComponent("in"); let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = inDir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let store = RuleStore(directory: dir)
        try await store.save(RuleLibrary(version: 1, rules: [
            Rule(id: UUID(), name: "移动", enabled: true, scopes: [.localFolder(path: inDir.path, recursive: true)],
                 trigger: .automatic, conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveTo(path: outDir.path)], executionMode: .automatic)]))

        let model = makeModel()
        await model.handleManualDrop(paths: [src.path])
        XCTAssertFalse(model.recentActivity.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
    }

    func test监控开关落盘() async throws {
        let model = makeModel()
        await model.setMonitoring(false)
        XCTAssertFalse(model.settings.monitoringEnabled)
        let reloaded = try await SettingsStore(directory: dir).load()
        XCTAssertFalse(reloaded.monitoringEnabled)
    }

    func test活动文本映射() {
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a.pdf", ops: [])
        XCTAssertTrue(AppModel.activityText(for: .executed(rec)).contains("R"))
        XCTAssertTrue(AppModel.activityText(for: .skipped(reason: "无匹配规则")).contains("无匹配"))
    }
}
