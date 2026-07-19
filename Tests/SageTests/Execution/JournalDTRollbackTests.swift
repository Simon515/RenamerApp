import XCTest
@testable import Sage

private actor SpyReverter: DTReverting {
    var reverted: [ReversibleOp] = []
    func revert(_ op: ReversibleOp) async throws { reverted.append(op) }
    func all() -> [ReversibleOp] { reverted }
}

final class JournalDTRollbackTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJDT-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDT操作回滚委托给DTReverter并逆序() async throws {
        let spy = SpyReverter()
        let journal = Journal(directory: dir, dtReverter: spy)
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a.pdf",
                                ops: [.dtImported(uuid: "U1", database: "D"),
                                      .dtRenamed(uuid: "U1", from: "旧", to: "新")])
        try await journal.append(rec)
        try await journal.rollback(id: rec.id)
        let seen = await spy.all()
        XCTAssertEqual(seen.count, 2)
        // 逆序：先撤销改名，再撤销导入
        XCTAssertEqual(seen.first, .dtRenamed(uuid: "U1", from: "旧", to: "新"))
        XCTAssertEqual(seen.last, .dtImported(uuid: "U1", database: "D"))
        let remaining = try await journal.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test无DTReverter时DT操作回滚报错且记录保留() async throws {
        let journal = Journal(directory: dir)
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a", ops: [.dtImported(uuid: "U", database: "D")])
        try await journal.append(rec)
        do {
            try await journal.rollback(id: rec.id)
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("DEVONthink"))
        }
        let remaining = try await journal.all()
        XCTAssertEqual(remaining.count, 1) // 失败不删记录
    }

    func testDT新case序列化往返() throws {
        let ops: [ReversibleOp] = [
            .dtImported(uuid: "U", database: "D"),
            .dtRenamed(uuid: "U", from: "a", to: "b"),
            .dtAddedTags(["x"], uuid: "U", previous: ["y"]),
            .dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/a", toDatabase: "D2", toGroup: "/b"),
        ]
        let data = try JSONEncoder().encode(ops)
        let back = try JSONDecoder().decode([ReversibleOp].self, from: data)
        XCTAssertEqual(back, ops)
    }

    func test日志描述覆盖DT操作() {
        XCTAssertTrue(JournalModel.describe(.dtImported(uuid: "U", database: "资料库")).contains("资料库"))
        XCTAssertTrue(JournalModel.describe(.dtRenamed(uuid: "U", from: "a", to: "b")).contains("b"))
        XCTAssertTrue(JournalModel.describe(.dtAddedTags(["t"], uuid: "U", previous: [])).contains("t"))
        XCTAssertTrue(JournalModel.describe(.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/a",
                                                     toDatabase: "D2", toGroup: "/b")).contains("/b"))
    }
}
