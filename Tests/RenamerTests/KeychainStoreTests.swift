import XCTest
@testable import Renamer

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "com.renamer.tests")
    private let account = "unit-test-key"

    override func tearDown() {
        // 清理测试条目，避免污染真实 Keychain。
        try? store.delete(account: account)
        super.tearDown()
    }

    func testWriteReadUpdateDeleteRoundTrip() throws {
        // 起始状态：不存在。
        try store.delete(account: account)
        XCTAssertNil(try store.read(account: account))

        // 写入并读取。
        try store.write(account: account, value: "secret-1")
        XCTAssertEqual(try store.read(account: account), "secret-1")

        // 更新。
        try store.write(account: account, value: "secret-2")
        XCTAssertEqual(try store.read(account: account), "secret-2")

        // 删除后再次读取为 nil；重复删除不报错。
        try store.delete(account: account)
        XCTAssertNil(try store.read(account: account))
        XCTAssertNoThrow(try store.delete(account: account))
    }
}
