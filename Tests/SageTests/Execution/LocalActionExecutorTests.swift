import XCTest
@testable import Sage

final class LocalActionExecutorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageExec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String, _ contents: String = "x") throws -> String {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func test移动到目录_保留原名() async throws {
        let src = try makeFile("a.pdf")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        let ops = try await exec.run(actions: [.moveTo(path: outDir.path)], on: .local(path: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
        XCTAssertEqual(ops.count, 1)
    }

    func test重命名用元数据模板() async throws {
        let src = try makeFile("scan.pdf")
        let provider = FakeMetadataProvider(result: .init(title: "发票2026"))
        let exec = LocalActionExecutor(metadataProvider: provider)
        let ops = try await exec.run(actions: [.llmExtractMetadata, .rename(template: "{title}")],
                                     on: .local(path: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("发票2026.pdf").path))
        XCTAssertEqual(provider.calls, 1)
        XCTAssertTrue(ops.contains(.renamed(from: src, to: dir.appendingPathComponent("发票2026.pdf").path)))
    }

    func test复制不改变当前位置_后续动作仍作用原文件() async throws {
        let src = try makeFile("a.txt")
        let copyDir = dir.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init(title: "改名")))
        _ = try await exec.run(actions: [.copyTo(path: copyDir.path), .llmExtractMetadata, .rename(template: "{title}")],
                               on: .local(path: src))
        // 副本仍叫 a.txt，原文件被改名为 改名.txt
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyDir.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("改名.txt").path))
    }

    func test非本地位置抛错() async {
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        do {
            _ = try await exec.run(actions: [.moveTo(path: "/out")],
                                   on: .devonthink(uuid: "X", database: "D", groupPath: "/G"))
            XCTFail("应抛 notLocalFile")
        } catch let e as ActionExecutionError {
            XCTAssertNotNil(e.errorDescription)
        } catch {
            XCTFail("应抛 ActionExecutionError")
        }
    }

    func test废纸篓仅runIncludingTrash允许() async throws {
        let src = try makeFile("del.txt")
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        // run 拒绝 trash
        do { _ = try await exec.run(actions: [.moveToTrash], on: .local(path: src)); XCTFail() }
        catch let e as ActionExecutionError { XCTAssertNotNil(e.errorDescription) }
        // runIncludingTrash 执行
        let ops = try await exec.runIncludingTrash(actions: [.moveToTrash], on: .local(path: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
        if case .trashed = ops.first {} else { XCTFail("应记 trashed") }
    }
}
