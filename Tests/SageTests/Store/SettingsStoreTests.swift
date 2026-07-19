import XCTest
@testable import Sage

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageSettings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test缺文件返回默认() async throws {
        let loaded = try await SettingsStore(directory: dir).load()
        XCTAssertEqual(loaded, SageSettings.defaults)
    }

    func test保存后加载往返() async throws {
        let store = SettingsStore(directory: dir)
        var s = SageSettings.defaults
        s.monitoringEnabled = false
        s.dailyLLMBudget = 200
        s.provider = ProviderSettings(enabled: true, baseURL: "https://api.deepseek.com/v1",
                                      model: "deepseek-chat", timeoutSeconds: 30)
        try await store.save(s)
        let reloaded = try await SettingsStore(directory: dir).load()
        XCTAssertEqual(reloaded, s)
    }

    func test高版本抛错() async throws {
        let future = #"{"version": 999, "monitoringEnabled": true, "launchAtLogin": false, "dailyLLMBudget": null, "provider": {"enabled": false, "baseURL": "", "model": "", "timeoutSeconds": 30}}"#
        try future.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        do { _ = try await SettingsStore(directory: dir).load(); XCTFail() }
        catch let e as SettingsStoreError { XCTAssertNotNil(e.errorDescription) }
    }
}
