import XCTest
@testable import Renamer

final class LocalAnalyzerTests: XCTestCase {
    func testAnalyzeTextFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Quarterly Rent Invoice March 2024".write(toFile: tmp.path(), atomically: true, encoding: .utf8)

        let item = FileItem(id: UUID(), url: tmp, name: tmp.lastPathComponent, pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        let analysis = try await LocalAnalyzer().analyze(item: item)

        XCTAssertTrue(analysis.title?.contains("Rent") == true || !analysis.tags.isEmpty)
    }
}
