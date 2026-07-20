import XCTest
@testable import Sage

/// 按脚本内容片段返回预设结果。
private final class ScriptedRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let byContains: [(needle: String, result: String)]
    init(_ byContains: [(String, String)]) { self.byContains = byContains }
    func run(_ source: String) async throws -> String { try lookup(source) }
    private func lookup(_ source: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        for (needle, result) in byContains where source.contains(needle) { return result }
        throw DTError.scriptFailed("unexpected script")
    }
}

/// 本地被误调用时立刻暴露。
private struct ThrowingFactsProvider: FactsProvider {
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts { throw DTError.scriptFailed("不应调用") }
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts { throw DTError.scriptFailed("不应调用") }
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("不应调用") }
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("不应调用") }
}

private actor SpyFactsProvider: FactsProvider {
    var cheapCalled = false
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        cheapCalled = true
        return CheapFacts(name: "n", fileExtension: "txt", sizeBytes: 1)
    }
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts { ExtractedFacts() }
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict { SemanticVerdict(matches: false, confidence: 0) }
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict { SemanticVerdict(matches: false, confidence: 0) }
}

final class DTFactsAdapterTests: XCTestCase {
    private let dtLoc = FileLocation.devonthink(uuid: "U", database: "D", groupPath: "/g")

    func testDT位置cheapFacts来自记录属性() async throws {
        let runner = ScriptedRunner([
            ("size of r", "发票 2026.pdf\tPDF 文稿\t2048\t2026-07-01T08:00:00\t2026-07-02T09:30:00"),
        ])
        let adapter = DTFactsAdapter(local: ThrowingFactsProvider(), runner: runner)
        let facts = try await adapter.cheapFacts(for: dtLoc)
        XCTAssertEqual(facts.name, "发票 2026")
        XCTAssertEqual(facts.fileExtension, "pdf")
        XCTAssertEqual(facts.sizeBytes, 2048)
        XCTAssertNotNil(facts.createdAt)
        XCTAssertNotNil(facts.modifiedAt)
    }

    func testDT位置无扩展名条目() async throws {
        let runner = ScriptedRunner([("size of r", "备忘录\t笔记\t10\tx\ty")])
        let adapter = DTFactsAdapter(local: ThrowingFactsProvider(), runner: runner)
        let facts = try await adapter.cheapFacts(for: dtLoc)
        XCTAssertEqual(facts.name, "备忘录")
        XCTAssertEqual(facts.fileExtension, "")
        XCTAssertNil(facts.createdAt) // 非法日期串 → nil，不崩溃
    }

    func testDT位置extractedFacts含纯文本与哈希() async throws {
        let runner = ScriptedRunner([("plain text of", "正文内容")])
        let adapter = DTFactsAdapter(local: ThrowingFactsProvider(), runner: runner)
        let facts = try await adapter.extractedFacts(for: dtLoc)
        XCTAssertEqual(facts.text, "正文内容")
        XCTAssertNotNil(facts.contentHash)
    }

    func test本地位置全部转发内层provider() async throws {
        let spy = SpyFactsProvider()
        let adapter = DTFactsAdapter(local: spy, runner: ScriptedRunner([]))
        _ = try await adapter.cheapFacts(for: .local(path: "/a"))
        let called = await spy.cheapCalled
        XCTAssertTrue(called)
    }

    func testDT位置LLM判定走文本入口() async throws {
        // 内层是 ExtractionProvider 才有文本入口；gateway 返回固定判定
        let gateway = LLMGateway(provider: FakeLLMProvider(content: #"{"matches": true, "confidence": 0.9}"#))
        let extraction = ExtractionProvider(gateway: gateway)
        let runner = ScriptedRunner([("plain text of", "这是一张发票")])
        let adapter = DTFactsAdapter(local: extraction, runner: runner)
        let verdict = try await adapter.belongsTo(category: "发票", at: dtLoc)
        XCTAssertTrue(verdict.matches)
    }
}
