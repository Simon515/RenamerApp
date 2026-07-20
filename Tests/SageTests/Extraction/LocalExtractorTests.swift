import XCTest
@testable import Sage

final class LocalExtractorTests: XCTestCase {
    private var tempDir: URL!
    private let extractor = LocalExtractor()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCheapFacts读取文件属性() throws {
        let url = tempDir.appendingPathComponent("Invoice.PDF")
        try Data("dummy".utf8).write(to: url)
        let facts = try extractor.cheapFacts(for: .local(path: url.path))
        XCTAssertEqual(facts.fileExtension, "pdf")
        XCTAssertEqual(facts.name, "Invoice")
        XCTAssertEqual(facts.sizeBytes, 5)
    }

    func testCheapFacts_DT位置返回空() throws {
        let facts = try extractor.cheapFacts(for: .devonthink(uuid: "X", database: "财务", groupPath: "/收件箱"))
        XCTAssertEqual(facts.name, "")
        XCTAssertEqual(facts.fileExtension, "")
    }

    func testExtractedFacts计算哈希() async throws {
        let url = tempDir.appendingPathComponent("a.txt")
        let content = "hello sage"
        try Data(content.utf8).write(to: url)
        let facts = try await extractor.extractedFacts(for: .local(path: url.path))
        XCTAssertNotNil(facts.contentHash)
        XCTAssertEqual(facts.contentHash?.count, 64) // SHA-256 十六进制长度
        XCTAssertNotNil(facts.text)
        XCTAssertTrue(facts.text!.contains("hello"))
    }

    func testExtractedFacts相同内容哈希一致() async throws {
        let url1 = tempDir.appendingPathComponent("a.txt")
        let url2 = tempDir.appendingPathComponent("b.txt")
        try Data("same".utf8).write(to: url1)
        try Data("same".utf8).write(to: url2)
        let f1 = try await extractor.extractedFacts(for: .local(path: url1.path))
        let f2 = try await extractor.extractedFacts(for: .local(path: url2.path))
        XCTAssertEqual(f1.contentHash, f2.contentHash)
    }
}