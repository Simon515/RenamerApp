import XCTest
@testable import Sage

final class AppleScriptEscapeTests: XCTestCase {
    func test转义五种元字符() {
        XCTAssertEqual(appleScriptEscape(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(appleScriptEscape(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(appleScriptEscape("a\nb"), #"a\nb"#)
        XCTAssertEqual(appleScriptEscape("a\rb"), #"a\rb"#)
        XCTAssertEqual(appleScriptEscape("a\tb"), #"a\tb"#)
    }

    func test先转义反斜杠避免双重转义() {
        // 若顺序错误，\" 会先变成 \\" 再被反斜杠规则二次处理（注入面）
        XCTAssertEqual(appleScriptEscape(#"\""#), #"\\\""#)
    }

    func test注入尝试被中和() {
        let hostile = #"x" & (do shell script "rm -rf ~") & ""#
        let escaped = appleScriptEscape(hostile)
        // 引号全部被转义，无法闭合字符串字面量逃出脚本结构
        XCTAssertFalse(escaped.contains(#"x" &"#))
        XCTAssertTrue(escaped.contains(#"\""#))
    }

    func testDTError中文消息() {
        XCTAssertEqual(DTError.notRunning.errorDescription, "DEVONthink 未运行，相关规则已暂停。")
        XCTAssertTrue(DTError.scriptFailed("boom").errorDescription!.contains("boom"))
        XCTAssertNotNil(DTError.needsLocalFile.errorDescription)
    }
}
