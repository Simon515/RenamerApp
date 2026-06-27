import XCTest
@testable import Renamer

final class DuplicateDetectorTests: XCTestCase {
    func testDetectsIdenticalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = Data("duplicate content".utf8)
        let a = dir.appending(path: "a.txt")
        let b = dir.appending(path: "b.txt")
        try data.write(to: a)
        try data.write(to: b)

        let items = [
            FileItem(id: UUID(), url: a, name: "a.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil),
            FileItem(id: UUID(), url: b, name: "b.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        ]

        let groups = try await DuplicateDetector().detectDuplicates(in: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.count, 2)
    }
}
