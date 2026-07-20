import XCTest
@testable import Sage

final class ConditionEvaluatorTests: XCTestCase {
    private let loc = FileLocation.local(path: "/in/a.pdf")

    func testName与扩展名() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "2026年3月发票", fileExtension: "pdf", sizeBytes: 100))
        let eval = ConditionEvaluator(provider: provider)
        let hit = try await eval.evaluate(.name(.contains("发票")), at: loc)
        let miss = try await eval.evaluate(.fileExtension(.equals("jpg")), at: loc)
        XCTAssertTrue(hit)
        XCTAssertFalse(miss)
    }

    func testSize区间() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 5000))
        let eval = ConditionEvaluator(provider: provider)
        let inRange = try await eval.evaluate(.sizeBytes(min: 1000, max: 10000), at: loc)
        let below = try await eval.evaluate(.sizeBytes(min: 6000, max: nil), at: loc)
        XCTAssertTrue(inRange)
        XCTAssertFalse(below)
    }

    func testCreatedWithinDays_用注入时钟() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: threeDaysAgo))
        let eval = ConditionEvaluator(provider: provider, now: { now })
        let within = try await eval.evaluate(.createdWithinDays(7), at: loc)
        let outside = try await eval.evaluate(.createdWithinDays(2), at: loc)
        XCTAssertTrue(within)
        XCTAssertFalse(outside)
    }

    func testCreatedWithinDays_无日期视为不匹配() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: nil))
        let eval = ConditionEvaluator(provider: provider)
        let result = try await eval.evaluate(.createdWithinDays(7), at: loc)
        XCTAssertFalse(result)
    }

    func testTextContent与重复() async throws {
        let provider = FakeFactsProvider(
            extracted: ExtractedFacts(text: "增值税发票 税号123", isDuplicate: true))
        let eval = ConditionEvaluator(provider: provider)
        let text = try await eval.evaluate(.textContent(.contains("税号")), at: loc)
        let dup = try await eval.evaluate(.isDuplicate, at: loc)
        XCTAssertTrue(text)
        XCTAssertTrue(dup)
    }

    func testContentBelongsTo_置信度阈值() async throws {
        let provider = FakeFactsProvider(
            verdicts: ["发票": SemanticVerdict(matches: true, confidence: 0.6)])
        let eval = ConditionEvaluator(provider: provider)
        let low = try await eval.evaluate(.contentBelongsTo(category: "发票", minConfidence: 0.7), at: loc)
        let ok = try await eval.evaluate(.contentBelongsTo(category: "发票", minConfidence: 0.5), at: loc)
        XCTAssertFalse(low)
        XCTAssertTrue(ok)
    }

    func testUTTypeConforms_一致性判断() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "jpg", sizeBytes: 1, utType: "public.jpeg"))
        let eval = ConditionEvaluator(provider: provider)
        let isImage = try await eval.evaluate(.utTypeConforms("public.image"), at: loc)
        let isMovie = try await eval.evaluate(.utTypeConforms("public.movie"), at: loc)
        let exact = try await eval.evaluate(.utTypeConforms("public.jpeg"), at: loc)
        XCTAssertTrue(isImage, "public.jpeg 应符合 public.image")
        XCTAssertFalse(isMovie, "public.jpeg 不应符合 public.movie")
        XCTAssertTrue(exact)
    }

    func testUTTypeConforms_无utType不匹配() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "jpg", sizeBytes: 1, utType: nil))
        let eval = ConditionEvaluator(provider: provider)
        let result = try await eval.evaluate(.utTypeConforms("public.image"), at: loc)
        XCTAssertFalse(result)
    }

    func testWithinDays_未来日期不匹配() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(2 * 86400)
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: future))
        let eval = ConditionEvaluator(provider: provider, now: { now })
        let result = try await eval.evaluate(.createdWithinDays(7), at: loc)
        XCTAssertFalse(result, "文件日期在未来应视为不匹配")
    }

    func testWithinDays_负天数不匹配() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: now))
        let eval = ConditionEvaluator(provider: provider, now: { now })
        let result = try await eval.evaluate(.createdWithinDays(-1), at: loc)
        XCTAssertFalse(result)
    }

    func testFree条件不触发提取与LLM() async throws {
        let provider = FakeFactsProvider()
        let eval = ConditionEvaluator(provider: provider)
        _ = try await eval.evaluate(.name(.contains("x")), at: loc)
        XCTAssertEqual(provider.extractionCalls, 0)
        XCTAssertEqual(provider.llmCalls, 0)
    }
}
