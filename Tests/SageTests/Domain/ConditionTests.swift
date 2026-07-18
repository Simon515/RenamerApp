import XCTest
@testable import Sage

final class ConditionTests: XCTestCase {
    func testTier_零成本条件() {
        XCTAssertEqual(Condition.name(.contains("发票")).tier, .free)
        XCTAssertEqual(Condition.fileExtension(.equals("pdf")).tier, .free)
        XCTAssertEqual(Condition.sizeBytes(min: 1, max: nil).tier, .free)
        XCTAssertEqual(Condition.createdWithinDays(7).tier, .free)
        XCTAssertEqual(Condition.modifiedWithinDays(7).tier, .free)
        XCTAssertEqual(Condition.utTypeConforms("com.adobe.pdf").tier, .free)
    }

    func testTier_提取条件() {
        XCTAssertEqual(Condition.textContent(.contains("税号")).tier, .extraction)
        XCTAssertEqual(Condition.isDuplicate.tier, .extraction)
        XCTAssertEqual(Condition.captureDateWithinDays(30).tier, .extraction)
        XCTAssertEqual(Condition.sourceURL(.contains("apple.com")).tier, .extraction)
    }

    func testTier_LLM条件() {
        XCTAssertEqual(Condition.contentBelongsTo(category: "发票", minConfidence: 0.7).tier, .llm)
        XCTAssertEqual(Condition.contentMatchesDescription("这是一张发票").tier, .llm)
    }

    func testTier_可比较() {
        XCTAssertLessThan(CostTier.free, CostTier.extraction)
        XCTAssertLessThan(CostTier.extraction, CostTier.llm)
    }

    func testCodable_往返() throws {
        let original = Condition.contentBelongsTo(category: "合同", minConfidence: 0.8)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Condition.self, from: data), original)
    }
}
