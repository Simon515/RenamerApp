import XCTest
@testable import Renamer

final class CloudAnalyzerTests: XCTestCase {
    func testParseResponse() throws {
        let json = """
        {
          "title": "Invoice",
          "category": "Invoices/2024",
          "tags": ["rent"],
          "source": "landlord",
          "confidence": 0.95
        }
        """
        let base = FileAnalysis(id: UUID(), title: nil, date: nil, category: nil, tags: [], source: nil, summary: nil, confidence: 0.5)
        let result = CloudAnalyzer(baseURL: URL(string: "http://localhost")!, apiKey: "", model: "").apply(json: json, to: base)
        XCTAssertEqual(result.title, "Invoice")
        XCTAssertEqual(result.category, "Invoices/2024")
    }
}
