import XCTest
@testable import Renamer

final class RollbackServiceTests: XCTestCase {
    private let fm = FileManager.default

    func testCopyRollbackRemovesDestination() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appending(path: "source.txt")
        let destination = dir.appending(path: "copied.txt")
        try "hello".write(toFile: source.path(), atomically: true, encoding: .utf8)
        try fm.copyItem(at: source, to: destination)

        let record = FileOperationRecord(
            id: UUID(),
            timestamp: Date(),
            taskName: "test",
            moves: [FileOperationRecord.Move(source: source, destination: destination, operation: .copy)],
            exports: []
        )

        try await RollbackService(recordsURL: dir).rollback(record: record)
        XCTAssertFalse(fm.fileExists(atPath: destination.path()))
        XCTAssertTrue(fm.fileExists(atPath: source.path()))
    }

    func testMoveRollbackRestoresSource() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appending(path: "source.txt")
        let destination = dir.appending(path: "moved.txt")
        try "hello".write(toFile: source.path(), atomically: true, encoding: .utf8)
        try fm.moveItem(at: source, to: destination)

        let record = FileOperationRecord(
            id: UUID(),
            timestamp: Date(),
            taskName: "test",
            moves: [FileOperationRecord.Move(source: source, destination: destination, operation: .move)],
            exports: []
        )

        try await RollbackService(recordsURL: dir).rollback(record: record)
        XCTAssertTrue(fm.fileExists(atPath: source.path()))
        XCTAssertFalse(fm.fileExists(atPath: destination.path()))
    }
}
