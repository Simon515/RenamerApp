import XCTest
@testable import Sage

final class SageKeychainStoreTests: XCTestCase {
    private let store = SageKeychainStore(service: "com.jiyuliang.Sage.tests.\(UUID().uuidString)")

    func test读不存在的account返回nil() throws {
        let result = try store.read(account: "不存在-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func test删除不存在的account不抛错() throws {
        XCTAssertNoThrow(try store.delete(account: "不存在-\(UUID().uuidString)"))
    }

    func testMissing错误描述含account名() {
        let error = SageKeychainError.missing(account: "DeepSeek")
        XCTAssertEqual(error.errorDescription, "Keychain 中未找到 account「DeepSeek」对应的 API Key。")
    }
}