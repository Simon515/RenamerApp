import XCTest
@testable import Sage

final class DTScriptBuilderTests: XCTestCase {
    func test导入脚本含转义与结构() {
        let s = DTScriptBuilder.importScript(
            filePath: #"/tmp/a "b".pdf"#, database: "资料库", groupPath: "/收件箱",
            tags: ["发票", "2026"], note: "摘要\"引号\"")
        XCTAssertTrue(s.contains(#"tell application id "DNtp""#))
        XCTAssertTrue(s.contains(#"import "/tmp/a \"b\".pdf""#))
        XCTAssertTrue(s.contains(#"get record at "/收件箱" in database "资料库""#))
        XCTAssertTrue(s.contains(#"{"发票", "2026"}"#))
        XCTAssertTrue(s.contains(#"摘要\"引号\""#))
        XCTAssertTrue(s.contains("return uuid of theRecord"))
    }

    func test导入脚本无标签无备注则省略对应语句() {
        let s = DTScriptBuilder.importScript(filePath: "/a", database: "D", groupPath: "/g", tags: [], note: nil)
        XCTAssertFalse(s.contains("set tags"))
        XCTAssertFalse(s.contains("set comment"))
    }

    func test重命名脚本返回旧名() {
        let s = DTScriptBuilder.renameScript(uuid: "U-1", newName: #"新"名"#)
        XCTAssertTrue(s.contains(#"get record with uuid "U-1""#))
        XCTAssertTrue(s.contains(#"set name of theRecord to "新\"名""#))
        XCTAssertTrue(s.contains("return oldName"))
    }

    func test加标签脚本返回旧标签() {
        let s = DTScriptBuilder.addTagsScript(uuid: "U", tags: ["a"])
        XCTAssertTrue(s.contains("set prev to tags of theRecord"))
        XCTAssertTrue(s.contains(#"prev & {"a"}"#))
        XCTAssertTrue(s.contains("linefeed"))
    }

    func test移动脚本返回旧位置() {
        let s = DTScriptBuilder.moveScript(uuid: "U", toDatabase: "D", toGroupPath: "/g")
        XCTAssertTrue(s.contains("location of theRecord"))
        XCTAssertTrue(s.contains("name of database of theRecord"))
        XCTAssertTrue(s.contains("move record theRecord to destGroup"))
    }

    func test注入恶意uuid被转义() {
        let s = DTScriptBuilder.deleteScript(uuid: #"x" -- do shell script "rm"#)
        // 恶意引号必须以 \" 形式出现，不得裸露成脚本结构
        XCTAssertTrue(s.contains(#"uuid "x\" -- do shell script \"rm""#))
    }

    func test回滚脚本() {
        XCTAssertTrue(DTScriptBuilder.setNameScript(uuid: "U", name: "旧").contains(#"to "旧""#))
        XCTAssertTrue(DTScriptBuilder.setTagsScript(uuid: "U", tags: ["a"]).contains(#"to {"a"}"#))
        XCTAssertTrue(DTScriptBuilder.deleteScript(uuid: "U").contains("delete record"))
    }

    func test列表与属性脚本() {
        let l = DTScriptBuilder.listGroupScript(database: "D", groupPath: "/g")
        XCTAssertTrue(l.contains("repeat with r in (children of theGroup)"))
        XCTAssertTrue(l.contains("«class isot»"))
        let f = DTScriptBuilder.factsScript(uuid: "U")
        XCTAssertTrue(f.contains("size of r"))
        let p = DTScriptBuilder.plainTextScript(uuid: "U")
        XCTAssertTrue(p.contains("plain text of"))
    }
}
