import XCTest
@testable import Renamer

final class DEVONthinkPluginTests: XCTestCase {
    func testCanHandle() {
        let plugin = DEVONthinkPlugin()
        XCTAssertTrue(plugin.canHandle(target: .devonthink(database: "db", group: "grp")))
    }

    func testEscapesQuotesAndBackslashes() {
        let plugin = DEVONthinkPlugin()
        let maliciousPath = "/tmp/\"quoted\\path\"/file.txt"
        let script = plugin.appleScript(
            forFile: URL(fileURLWithPath: maliciousPath),
            target: .devonthink(database: "db\"with\\quote", group: "grp\"with\\quote")
        )

        // 原始危险字符不应直接出现在脚本字符串中。
        XCTAssertFalse(script.contains("\"quoted\\path\""))
        XCTAssertFalse(script.contains("db\"with\\quote"))
        XCTAssertFalse(script.contains("grp\"with\\quote"))

        // 应已正确转义为 AppleScript 字符串字面量。
        XCTAssertTrue(script.contains("\\\"quoted\\\\path\\\""))
        XCTAssertTrue(script.contains("db\\\"with\\\\quote"))
        XCTAssertTrue(script.contains("grp\\\"with\\\\quote"))
    }
}
