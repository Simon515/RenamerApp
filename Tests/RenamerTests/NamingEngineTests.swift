import XCTest
@testable import Renamer

final class NamingEngineTests: XCTestCase {
    func testBuildPlan() throws {
        let tmp = FileManager.default.temporaryDirectory
        let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{title}")
        let dest = tmp.appending(path: "out")
        let task = OrganizationTask(
            id: UUID(),
            name: "test",
            sourceFolders: [],
            templateID: template.id,
            destinationFolder: dest,
            operation: .copy,
            exportTargets: [],
            useCloudAI: false
        )
        let src = tmp.appending(path: "source.txt")
        let item = FileItem(id: UUID(), url: src, name: "source.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        let analysis = FileAnalysis(id: item.id, title: "Invoice", date: nil, category: "Docs", tags: [], source: nil, summary: nil, confidence: 0.9)

        let engine = NamingEngine(template: template, destination: dest)
        let plan = try engine.buildPlan(taskID: task.id, items: [item], analyses: [analysis], duplicateGroups: [])

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operation, .copy)
        XCTAssertTrue(plan.operations.first!.destination.path().contains("/Docs/"))
        XCTAssertTrue(plan.operations.first!.destination.lastPathComponent.hasPrefix("Invoice"))
    }
}
