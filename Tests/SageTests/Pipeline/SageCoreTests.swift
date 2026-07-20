import XCTest
@testable import Sage

final class SageCoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageCore-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test端到端_手动录入触发自动移动规则() async throws {
        // 源文件
        let inDir = dir.appendingPathComponent("in")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = inDir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)

        // 规则库：pdf → 移动到 out（手动作用域也覆盖，用 localFolder 递归 in）
        let store = RuleStore(directory: dir)
        let rule = Rule(id: UUID(), name: "移动PDF", enabled: true,
                        scopes: [.localFolder(path: inDir.path, recursive: true)],
                        trigger: .automatic, conditionLogic: .all,
                        conditions: [.fileExtension(.equals("pdf"))],
                        actions: [.moveTo(path: outDir.path)], executionMode: .automatic)
        try await store.save(RuleLibrary(version: 1, rules: [rule]))

        // gateway 用假 provider（本用例不触发 LLM）
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        let assembled = SageCore.makeDefault(supportDirectory: dir, gateway: gateway)

        let events = assembled.manualIntake.events(forDroppedPaths: [src.path])
        XCTAssertEqual(events.count, 1)
        let outcomes = await assembled.coordinator.handle(events[0])
        if case .executed = outcomes.first {} else { XCTFail("应 executed，实际 \(outcomes)") }
        let movedExists = FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path)
        let srcExists = FileManager.default.fileExists(atPath: src.path)
        XCTAssertTrue(movedExists)
        XCTAssertFalse(srcExists)
    }
}
