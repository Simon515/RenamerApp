import XCTest
@testable import Sage

final class ManualIntakeTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageIntake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func test单文件产一个事件() throws {
        try write("a.pdf")
        let events = ManualIntake().events(forDroppedPaths: [dir.appendingPathComponent("a.pdf").path])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.source, .manual)
    }

    func test目录递归展开跳过隐藏() throws {
        try write("a.pdf"); try write("sub/b.txt"); try write(".hidden"); try write(".git/c")
        let events = ManualIntake().events(forDroppedPaths: [dir.path])
        let names = Set(events.compactMap { loc -> String? in
            if case .local(let p) = loc.location { return (p as NSString).lastPathComponent }
            return nil
        })
        XCTAssertEqual(names, ["a.pdf", "b.txt"])
    }

    func test去重() throws {
        try write("a.pdf")
        let p = dir.appendingPathComponent("a.pdf").path
        let events = ManualIntake().events(forDroppedPaths: [p, p])
        XCTAssertEqual(events.count, 1)
    }
}
