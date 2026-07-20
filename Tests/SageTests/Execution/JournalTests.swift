import XCTest
@testable import Sage

final class JournalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJournal-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func record(ops: [ReversibleOp], at date: Date) -> JournalRecord {
        JournalRecord(id: UUID(), timestamp: date, ruleID: UUID(), ruleName: "R",
                      sourceDescription: "s", ops: ops)
    }

    func test追加与倒序读取() async throws {
        let journal = Journal(directory: dir)
        let older = record(ops: [], at: Date(timeIntervalSince1970: 1))
        let newer = record(ops: [], at: Date(timeIntervalSince1970: 2))
        try await journal.append(older)
        try await journal.append(newer)
        let all = try await journal.all()
        XCTAssertEqual(all.map(\.id), [newer.id, older.id])
    }

    func test持久化跨实例() async throws {
        let r = record(ops: [], at: Date(timeIntervalSince1970: 1))
        try await Journal(directory: dir).append(r)
        let reloaded = try await Journal(directory: dir).all()
        XCTAssertEqual(reloaded.map(\.id), [r.id])
    }

    func test截断保留最新() async throws {
        let journal = Journal(directory: dir, maxRecords: 2)
        for i in 1...3 { try await journal.append(record(ops: [], at: Date(timeIntervalSince1970: TimeInterval(i)))) }
        let all = try await journal.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map { $0.timestamp.timeIntervalSince1970 }, [3, 2])
    }

    func test回滚move() async throws {
        let src = try makeFile("a.pdf")
        let dst = dir.appendingPathComponent("moved.pdf").path
        try FileManager.default.moveItem(atPath: src, toPath: dst)
        let journal = Journal(directory: dir)
        let r = record(ops: [.moved(from: src, to: dst)], at: Date())
        try await journal.append(r)
        try await journal.rollback(id: r.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        let remaining = try await journal.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test回滚copy删副本() async throws {
        let copy = try makeFile("copy.pdf")
        let journal = Journal(directory: dir)
        let r = record(ops: [.copied(to: copy)], at: Date())
        try await journal.append(r)
        try await journal.rollback(id: r.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    func test回滚trash无路径抛错() async throws {
        let journal = Journal(directory: dir)
        let r = record(ops: [.trashed(originalPath: "/x", trashPath: nil)], at: Date())
        try await journal.append(r)
        do { try await journal.rollback(id: r.id); XCTFail() }
        catch let e as JournalError { XCTAssertNotNil(e.errorDescription) }
    }
}
