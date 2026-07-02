import XCTest
@testable import Renamer

final class AnalysisPipelineTests: XCTestCase {
    private func makeRequest(folders: [URL], destination: URL) -> AnalysisRequest {
        AnalysisRequest(
            folders: folders,
            taskID: nil,
            template: NamingTemplate(id: UUID(), name: "test", folderTemplate: "{category}", fileNameTemplate: "{title}"),
            destination: destination,
            operation: .copy,
            exportTargets: [],
            cloudConfig: nil
        )
    }

    func testFullPipelineProducesPlan() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "First report content".write(toFile: dir.appending(path: "a.txt").path(), atomically: true, encoding: .utf8)
        try "Second report content".write(toFile: dir.appending(path: "b.txt").path(), atomically: true, encoding: .utf8)

        let outcome = try await AnalysisPipeline().run(makeRequest(folders: [dir], destination: dir.appending(path: "out"))) { _ in }

        XCTAssertEqual(outcome.plan.operations.count, 2)
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.plan.analyses.count, 2)
        XCTAssertTrue(outcome.plan.duplicateGroups.isEmpty)
        XCTAssertEqual(outcome.analysisFailureCount, 0)
        XCTAssertEqual(outcome.cloudFailureCount, 0)
    }

    func testDuplicatesAreGroupedAndSkipped() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "identical content".write(toFile: dir.appending(path: "a.txt").path(), atomically: true, encoding: .utf8)
        try "identical content".write(toFile: dir.appending(path: "b.txt").path(), atomically: true, encoding: .utf8)
        try "unique content".write(toFile: dir.appending(path: "c.txt").path(), atomically: true, encoding: .utf8)

        let outcome = try await AnalysisPipeline().run(makeRequest(folders: [dir], destination: dir.appending(path: "out"))) { _ in }

        XCTAssertEqual(outcome.plan.duplicateGroups.count, 1)
        XCTAssertEqual(outcome.plan.duplicateGroups.first?.items.count, 2)
        // 重复组默认保留一份，因此操作数为 2（1 个重复组保留项 + 1 个独立文件）。
        XCTAssertEqual(outcome.plan.operations.count, 2)
    }

    func testProgressEventsAreEmitted() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "some content".write(toFile: dir.appending(path: "a.txt").path(), atomically: true, encoding: .utf8)

        let recorder = ProgressRecorder()
        _ = try await AnalysisPipeline().run(makeRequest(folders: [dir], destination: dir.appending(path: "out"))) { progress in
            recorder.record(progress)
        }

        let events = recorder.events
        XCTAssertTrue(events.contains { if case .scanning = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .buildingPlan = $0 { return true }; return false })
    }
}

/// 线程安全的进度事件记录器，供并发回调中收集事件。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AnalysisProgress] = []

    var events: [AnalysisProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ progress: AnalysisProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(progress)
    }
}
