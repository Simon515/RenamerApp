import XCTest
@testable import Sage

final class BoundedCacheTests: XCTestCase {
    func test达到容量淘汰最旧项() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3  // 触发淘汰最旧的 "a"
        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }

    func test更新已存在键不改变淘汰顺序() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        cache["a"] = 10  // 更新，不应把 a 变为最新
        cache["c"] = 3   // 淘汰最旧 a
        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
    }

    func test删除键() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["a"] = nil
        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache.count, 0)
    }
}
