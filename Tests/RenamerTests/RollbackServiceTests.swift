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

    func testRollbackContinuesAfterPartialFailure() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source1 = dir.appending(path: "a.txt")
        let destination1 = dir.appending(path: "a_copy.txt")
        let source2 = dir.appending(path: "b.txt")
        let destination2 = dir.appending(path: "b_copy.txt")
        try "a".write(toFile: source1.path(), atomically: true, encoding: .utf8)
        try "b".write(toFile: source2.path(), atomically: true, encoding: .utf8)
        try fm.copyItem(at: source1, to: destination1)

        let record = FileOperationRecord(
            id: UUID(),
            timestamp: Date(),
            taskName: "test",
            moves: [
                FileOperationRecord.Move(source: source1, destination: destination1, operation: .copy),
                FileOperationRecord.Move(source: source2, destination: destination2, operation: .copy)
            ],
            exports: []
        )

        var thrown: Error?
        do {
            try await RollbackService(recordsURL: dir).rollback(record: record)
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown)
        XCTAssertFalse(fm.fileExists(atPath: destination1.path()))
    }

    func testListAndDeleteRecords() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let record = FileOperationRecord(
            id: UUID(),
            timestamp: Date(),
            taskName: "list-test",
            moves: [],
            exports: []
        )

        let service = RollbackService(recordsURL: dir)
        try await service.save(record: record)

        let listed = await service.listRecords()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.taskName, "list-test")

        try await service.deleteRecord(id: record.id)
        let afterDelete = await service.listRecords()
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
