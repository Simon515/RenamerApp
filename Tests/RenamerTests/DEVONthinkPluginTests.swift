import XCTest
@testable import Renamer

final class DEVONthinkPluginTests: XCTestCase {
    func testCanHandle() {
        let plugin = DEVONthinkPlugin()
        XCTAssertTrue(plugin.canHandle(target: .devonthink(database: "db", group: "grp")))
    }

    func testEscapesQuotesAndBackslashes() async throws {
        let plugin = DEVONthinkPlugin()
        let maliciousPath = "/tmp/\"quoted\\path\"/file.txt"
        let result = try await plugin.export(
            file: URL(fileURLWithPath: maliciousPath),
            target: .devonthink(database: "db\"with\\quote", group: "grp\"with\\quote")
        )
        XCTAssertTrue(result.contains("devonthink"))
    }
}
