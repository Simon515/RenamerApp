import XCTest
@testable import Sage

final class RuleStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var sampleRule: Rule {
        Rule(id: UUID(), name: "发票归档", enabled: true,
             scopes: [.localFolder(path: "/in", recursive: true)],
             trigger: .automatic, conditionLogic: .all,
             conditions: [.fileExtension(.equals("pdf"))],
             actions: [.dtImport(database: "财务", groupPath: "/发票", tags: ["发票"], noteTemplate: nil)],
             executionMode: .confirmFirst)
    }

    func test文件不存在返回空库() async throws {
        let store = RuleStore(directory: tempDir)
        let library = try await store.load()
        XCTAssertEqual(library, RuleLibrary(version: 1, rules: []))
    }

    func test保存后读回_顺序保持() async throws {
        let store = RuleStore(directory: tempDir)
        var second = sampleRule
        second.id = UUID()
        second.name = "第二条"
        let library = RuleLibrary(version: 1, rules: [sampleRule, second])
        try await store.save(library)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, library)
        XCTAssertEqual(loaded.rules.map(\.name), ["发票归档", "第二条"])
    }

    func test不支持的版本抛错() async throws {
        let json = #"{"version": 99, "rules": []}"#
        try json.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("rules.json"))
        let store = RuleStore(directory: tempDir)
        do {
            _ = try await store.load()
            XCTFail("应当抛出 unsupportedVersion")
        } catch let error as RuleStoreError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription!.contains("99"))
        }
    }
}