import XCTest
@testable import Sage

final class StringMatchTests: XCTestCase {
    func testEquals_忽略大小写() {
        XCTAssertTrue(StringMatch.equals("Invoice.PDF").matches("invoice.pdf"))
    }

    func testContains() {
        XCTAssertTrue(StringMatch.contains("发票").matches("2026年3月发票扫描件"))
        XCTAssertFalse(StringMatch.contains("发票").matches("收据"))
    }

    func testRegex() {
        XCTAssertTrue(StringMatch.regex(#"^\d{4}-\d{2}"#).matches("2026-03 report"))
        XCTAssertFalse(StringMatch.regex(#"^\d{4}-\d{2}"#).matches("report 2026"))
    }

    func testRegex_非法模式返回不匹配() {
        XCTAssertFalse(StringMatch.regex("([").matches("anything"))
    }

    func testCodable_往返() throws {
        let original = StringMatch.regex(#"\d+"#)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StringMatch.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
