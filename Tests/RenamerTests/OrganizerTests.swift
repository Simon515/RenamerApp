import XCTest
@testable import Renamer

final class OrganizerTests: XCTestCase {
    private let fm = FileManager.default

    func testCopyFiles() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let op = PlanOperation(id: UUID(), source: src, destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [])

        let record = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertTrue(fm.fileExists(atPath: dest.path()))
        XCTAssertTrue(fm.fileExists(atPath: src.path()))
        XCTAssertEqual(record.moves.count, 1)
        XCTAssertEqual(record.moves.first?.operation, .copy)
    }

    func testMoveFiles() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let op = PlanOperation(id: UUID(), source: src, destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [])

        let record = try await Organizer().execute(plan: plan, taskName: "test", operation: .move)
        XCTAssertTrue(fm.fileExists(atPath: dest.path()))
        XCTAssertFalse(fm.fileExists(atPath: src.path()))
        XCTAssertEqual(record.moves.first?.operation, .move)
    }

    func testExportPluginsAreExecuted() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let target: ExportTarget = .devonthink(database: "TestDB", group: "Inbox")
        let op = PlanOperation(id: UUID(), source: src, destination: dest, exportTargets: [target], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [])

        let record = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertEqual(record.exports.count, 1)
        XCTAssertEqual(record.exports.first?.pluginID, "devonthink")
    }
}
