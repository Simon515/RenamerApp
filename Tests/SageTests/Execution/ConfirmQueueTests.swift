import XCTest
@testable import Sage

final class ConfirmQueueTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageQueue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ n: Int) -> PendingItem {
        let event = FileEvent(location: .local(path: "/in/\(n).pdf"), source: .manual)
        let planned = PlannedActions(ruleID: UUID(), ruleName: "R\(n)", location: .local(path: "/in/\(n).pdf"),
                                     actions: [.moveToTrash], requiresConfirmation: true)
        return PendingItem(id: UUID(), enqueuedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                           event: FileEventSnapshot(from: event), planned: PlannedActionsSnapshot(from: planned))
    }

    func test入队与顺序读取() async throws {
        let q = ConfirmQueue(directory: dir)
        let a = item(1); let b = item(2)
        try await q.enqueue(a); try await q.enqueue(b)
        let ids = try await q.all().map(\.id)
        XCTAssertEqual(ids, [a.id, b.id])
        let count = try await q.count()
        XCTAssertEqual(count, 2)
    }

    func test持久化跨实例与按id查移() async throws {
        let a = item(1)
        try await ConfirmQueue(directory: dir).enqueue(a)
        let q2 = ConfirmQueue(directory: dir)
        let foundID = try await q2.item(id: a.id)?.id
        XCTAssertEqual(foundID, a.id)
        try await q2.remove(id: a.id)
        let afterRemove = try await q2.item(id: a.id)
        XCTAssertNil(afterRemove)
        let count = try await q2.count()
        XCTAssertEqual(count, 0)
    }
}
