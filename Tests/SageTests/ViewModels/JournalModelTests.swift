import XCTest
@testable import Sage

@MainActor
final class JournalModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJournalVM-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test加载与回滚() async throws {
        // 造一个真实 move 记录并回滚
        let src = dir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let dst = dir.appendingPathComponent("moved.pdf")
        try FileManager.default.moveItem(at: src, to: dst)
        let journal = Journal(directory: dir)
        let record = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                   sourceDescription: src.path, ops: [.moved(from: src.path, to: dst.path)])
        try await journal.append(record)
        let model = JournalModel(journal: journal)
        await model.reload()
        XCTAssertEqual(model.records.count, 1)
        await model.rollback(id: record.id)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path)) // 已移回
    }

    func test摘要与操作描述() {
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "发票归档",
                                sourceDescription: "/in/a.pdf", ops: [.moved(from: "/in/a.pdf", to: "/out/a.pdf")])
        XCTAssertTrue(JournalModel.summary(rec).contains("发票归档"))
        XCTAssertEqual(JournalModel.describe(.moved(from: "/a", to: "/b")), "移动 /a → /b")
        XCTAssertEqual(JournalModel.describe(.trashed(originalPath: "/a", trashPath: nil)), "移到废纸篓 /a")
    }
}
