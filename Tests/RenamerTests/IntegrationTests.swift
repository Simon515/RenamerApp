import XCTest
@testable import Renamer

final class IntegrationTests: XCTestCase {
    func testEndToEndCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appending(path: "report.txt")
        try "Monthly Report".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out")
        let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "Reports", fileNameTemplate: "{title}")

        let scanner = FileScanner()
        let scanResult = await scanner.scan(folders: [dir])
        let items = scanResult.items
        var analyses: [FileAnalysis] = []
        for item in items {
            analyses.append(try await LocalAnalyzer().analyze(item: item))
        }
        let result = await DuplicateDetector().detectDuplicates(in: items)
        let plan = try NamingEngine(template: template, destination: dest)
            .buildPlan(taskID: nil, items: items, analyses: analyses, duplicateGroups: result.groups, operation: .copy)

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operation, .copy)
        let record = try await Organizer().execute(plan: plan, taskName: "integration").record
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.moves.first!.destination.path()))
    }
}
