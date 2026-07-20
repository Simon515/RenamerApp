import XCTest
@testable import Sage

final class FileEventTests: XCTestCase {
    func testScope_本地非递归_仅直接子文件() {
        let scope = RuleScope.localFolder(path: "/in", recursive: false)
        let direct = FileEvent(location: .local(path: "/in/a.pdf"), source: .manual)
        let nested = FileEvent(location: .local(path: "/in/sub/a.pdf"), source: .manual)
        XCTAssertTrue(direct.isCovered(by: scope))
        XCTAssertFalse(nested.isCovered(by: scope))
    }

    func testScope_本地递归_含子目录() {
        let scope = RuleScope.localFolder(path: "/in", recursive: true)
        let nested = FileEvent(location: .local(path: "/in/sub/deep/a.pdf"), source: .manual)
        XCTAssertTrue(nested.isCovered(by: scope))
    }

    func testScope_路径前缀不越界() {
        // "/inbox" 不应被 "/in" 覆盖
        let scope = RuleScope.localFolder(path: "/in", recursive: true)
        let outside = FileEvent(location: .local(path: "/inbox/a.pdf"), source: .manual)
        XCTAssertFalse(outside.isCovered(by: scope))
    }

    func testScope_DT位置匹配库与组() {
        let scope = RuleScope.devonthink(database: "财务", groupPath: "/收件箱")
        let hit = FileEvent(location: .devonthink(uuid: "X", database: "财务", groupPath: "/收件箱"),
                            source: .dtWatch(database: "财务", groupPath: "/收件箱"))
        let miss = FileEvent(location: .devonthink(uuid: "Y", database: "个人", groupPath: "/收件箱"),
                             source: .dtWatch(database: "个人", groupPath: "/收件箱"))
        XCTAssertTrue(hit.isCovered(by: scope))
        XCTAssertFalse(miss.isCovered(by: scope))
    }

    func testScope_manualOnly_只覆盖手动来源() {
        let scope = RuleScope.manualOnly
        XCTAssertTrue(FileEvent(location: .local(path: "/x/a.pdf"), source: .manual).isCovered(by: scope))
        XCTAssertFalse(FileEvent(location: .local(path: "/x/a.pdf"),
                                 source: .folderWatch(root: "/x")).isCovered(by: scope))
    }
}
