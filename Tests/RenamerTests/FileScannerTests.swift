import XCTest
@testable import Renamer

final class FileScannerTests: XCTestCase {
    func testScanEmptyFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let items = try await FileScanner().scan(folders: [tmp])
        XCTAssertEqual(items.count, 0)
    }

    func testScanSkipsHiddenFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "hello".write(toFile: tmp.appending(path: "visible.txt").path(), atomically: true, encoding: .utf8)
        try "hidden".write(toFile: tmp.appending(path: ".hidden.txt").path(), atomically: true, encoding: .utf8)

        let items = try await FileScanner().scan(folders: [tmp])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "visible.txt")
    }
}
