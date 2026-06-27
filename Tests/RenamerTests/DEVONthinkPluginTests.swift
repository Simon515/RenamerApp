import XCTest
@testable import Renamer

final class DEVONthinkPluginTests: XCTestCase {
    func testCanHandle() {
        let plugin = DEVONthinkPlugin()
        XCTAssertTrue(plugin.canHandle(target: .devonthink(database: "db", group: "grp")))
    }
}
