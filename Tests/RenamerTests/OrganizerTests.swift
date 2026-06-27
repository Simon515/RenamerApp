import XCTest
@testable import Renamer

final class OrganizerTests: XCTestCase {
    func testCopyFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let op = PlanOperation(id: UUID(), source: src, destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [])

        let record = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path()))
        XCTAssertEqual(record.moves.count, 1)
    }
}
