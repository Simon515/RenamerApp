import XCTest
@testable import Sage

final class ExtractionProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, content: String) -> String {
        let url = tempDir.appendingPathComponent(name)
        try? Data(content.utf8).write(to: url)
        return url.path
    }

    func testCheapFacts转发() async throws {
        let path = makeFile("Doc.PDF", content: "x")
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")))
        let facts = try await provider.cheapFacts(for: .local(path: path))
        XCTAssertEqual(facts.fileExtension, "pdf")
    }

    func testExtractedFacts按哈希缓存不重复提取() async throws {
        let path = makeFile("a.txt", content: "same content")
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")))
        let f1 = try await provider.extractedFacts(for: .local(path: path))
        let f2 = try await provider.extractedFacts(for: .local(path: path))
        XCTAssertEqual(f1.contentHash, f2.contentHash)
    }

    func testBelongsTo走LLMGateway() async throws {
        let path = makeFile("a.txt", content: "增值税发票 税号123")
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)))
        let verdict = try await provider.belongsTo(category: "发票", at: .local(path: path))
        XCTAssertTrue(verdict.matches)
        XCTAssertEqual(verdict.confidence, 0.9)
    }

    func test重复文件isDuplicate为true() async throws {
        let path1 = makeFile("a.txt", content: "dup")
        let path2 = makeFile("b.txt", content: "dup")
        let registry = DuplicateRegistry()
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")),
                                          duplicateRegistry: registry)
        let f1 = try await provider.extractedFacts(for: .local(path: path1))
        // 同内容第二次
        let f2 = try await provider.extractedFacts(for: .local(path: path2))
        // 第二个文件应被标记为重复（哈希相同且已在 registry 注册）
        XCTAssertTrue(f2.isDuplicate, "同哈希的第二个文件应被标记为重复")
        XCTAssertFalse(f1.isDuplicate)
    }
}