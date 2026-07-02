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
        let op = PlanOperation(id: UUID(), source: src, analysisID: UUID(), destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [], operation: .copy)

        let result = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertTrue(fm.fileExists(atPath: dest.path()))
        XCTAssertTrue(fm.fileExists(atPath: src.path()))
        XCTAssertEqual(result.record.moves.count, 1)
        XCTAssertEqual(result.record.moves.first?.operation, .copy)
        XCTAssertEqual(result.skippedCount, 0)
    }

    func testMoveFiles() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let op = PlanOperation(id: UUID(), source: src, analysisID: UUID(), destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [], operation: .move)

        let record = try await Organizer().execute(plan: plan, taskName: "test", operation: .move).record
        XCTAssertTrue(fm.fileExists(atPath: dest.path()))
        XCTAssertFalse(fm.fileExists(atPath: src.path()))
        XCTAssertEqual(record.moves.first?.operation, .move)
    }

    func testExistingDestinationIsSkipped() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let outDir = dir.appending(path: "out")
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let dest = outDir.appending(path: "a.txt")
        try "existing".write(toFile: dest.path(), atomically: true, encoding: .utf8)

        let op = PlanOperation(id: UUID(), source: src, analysisID: UUID(), destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [], operation: .copy)

        let result = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.record.moves.count, 0)
        // 已存在的目标文件内容不应被覆盖。
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "existing")
    }

    func testExportPluginsAreExecuted() async throws {
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let target: ExportTarget = .devonthink(database: "TestDB", group: "Inbox")
        let op = PlanOperation(id: UUID(), source: src, analysisID: UUID(), destination: dest, exportTargets: [target], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [], operation: .copy)

        let record = try await Organizer().execute(plan: plan, taskName: "test").record
        XCTAssertEqual(record.exports.count, 1)
        XCTAssertEqual(record.exports.first?.pluginID, "devonthink")
    }
}
