import XCTest
@testable import Sage

final class ExecutionRecordsTests: XCTestCase {
    func testJournalRecord_Codable往返() throws {
        let record = JournalRecord(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            ruleID: UUID(), ruleName: "发票归档", sourceDescription: "/in/a.pdf",
            ops: [.renamed(from: "/in/a.pdf", to: "/in/2026-发票.pdf"),
                  .moved(from: "/in/2026-发票.pdf", to: "/out/2026-发票.pdf")])
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(JournalRecord.self, from: data), record)
    }

    func testPendingItem_从FileEvent与PlannedActions构造并往返() throws {
        let event = FileEvent(location: .local(path: "/in/a.pdf"), source: .folderWatch(root: "/in"))
        let planned = PlannedActions(ruleID: UUID(), ruleName: "R", location: .local(path: "/in/a.pdf"),
                                     actions: [.moveTo(path: "/out")], requiresConfirmation: true)
        let item = PendingItem(id: UUID(), enqueuedAt: Date(timeIntervalSince1970: 1),
                               event: FileEventSnapshot(from: event),
                               planned: PlannedActionsSnapshot(from: planned))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(PendingItem.self, from: data)
        XCTAssertEqual(decoded, item)
        // 快照可还原回领域类型
        XCTAssertEqual(decoded.event.fileEvent, event)
        XCTAssertEqual(decoded.planned.plannedActions, planned)
    }

    func testActionOutcome_Equatable() {
        let a = ActionOutcome.skipped(reason: "无匹配规则")
        let b = ActionOutcome.skipped(reason: "无匹配规则")
        XCTAssertEqual(a, b)
    }
}
