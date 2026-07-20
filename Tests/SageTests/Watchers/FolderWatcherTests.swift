import XCTest
@testable import Sage

final class FolderWatcherTests: XCTestCase {
    func test分类_保留文件事件过滤删除与隐藏() {
        let paths = ["/w/a.pdf", "/w/.ds_store", "/w/gone.txt", "/w/sub/b.txt"]
        let flags: [FolderWatcher.EventFlag] = [
            [.isFile],                    // a.pdf 保留
            [.isFile],                    // .ds_store 隐藏，过滤
            [.isFile, .removed],          // gone.txt 已删除，过滤
            [.isFile],                    // b.txt 保留
        ]
        let result = FolderWatcher.classify(paths: paths, flags: flags)
        XCTAssertEqual(result, ["/w/a.pdf", "/w/sub/b.txt"])
    }

    func test分类_过滤目录事件() {
        let result = FolderWatcher.classify(paths: ["/w/dir"], flags: [[.isDir]])
        XCTAssertTrue(result.isEmpty)
    }
}
