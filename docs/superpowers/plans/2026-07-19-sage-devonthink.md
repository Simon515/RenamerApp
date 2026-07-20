# Sage DEVONthink 集成 Implementation Plan（第 5 份 / 最终份）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落实 spec §5：DT 动作真实执行（AppleScript、转义防注入）、DT 导入回滚、DT 组轮询监控、DT 条目 FileFacts、DT 未运行暂停提示，以及规则编辑器的 DT 参数 UI。

**Architecture:** 把「脚本构造」（纯函数，XCTest 全覆盖转义/注入）与「脚本执行」（`AppleScriptRunning` 协议：真实实现 `NSAppleScriptRunner` + 测试用 Fake）分层。`DTActions` 实现既有 `DTActionExecutor` 协议替换 `UnimplementedDTActionExecutor`；`DTWatcher` 轮询产出 `FileEvent`；`DTFactsAdapter` 包装既有 `FactsProvider` 把 `.devonthink` 位置路由到 DT 查询。DT 为外部应用：所有经真实 DT 的路径只做构建验证 + 手动清单（spec §9）。

**Tech Stack:** Swift 6（StrictConcurrency）、NSAppleScript（`tell application id "DNtp"`，DT3/DT4 通用）、NSRunningApplication、XCTest。

## Global Constraints（每个任务隐含）

- 插入 AppleScript 的字符串一律经 `appleScriptEscape` 转义（`\` `"` `\n` `\r` `\t`，先转义反斜杠）——防注入，spec §5。
- API Key 只存 Keychain（account `"llm-api-key"`），settings.json 无密钥字段。
- 删除类动作强制入确认队列；不得为 DT 删除开旁路。
- 从不覆盖已有文件。
- 错误类型遵循 `LocalizedError` 返回中文消息（spec §8）。
- DT 未运行：相关规则暂停、菜单栏提示、不弹错误（spec §5/§8）。
- 测试命令必须 `swift test --filter <套件名>` 或 `--filter SageTests`，**绝不裸 `swift test`**（遗留 RenamerTests 挂起）。构建 `swift build`。
- DT 交互不做自动化测试（spec §9）：真实 NSAppleScript 路径只构建验证；逻辑经 Fake runner 测试。
- 现有 142+ 项 SageTests 必须保持全绿。

## File Structure

| 文件 | 职责 |
|---|---|
| `Sources/Sage/DT/AppleScriptRunning.swift`（新） | runner 协议、`DTError`、`NSAppleScriptRunner`、`appleScriptEscape` |
| `Sources/Sage/DT/DTScriptBuilder.swift`（新） | 全部 AppleScript 源码构造（纯函数） |
| `Sources/Sage/DT/DTActions.swift`（新） | `DTActionExecutor` 真实实现 + `DTReverting` 回滚实现 |
| `Sources/Sage/DT/DTFactsAdapter.swift`（新） | `.devonthink` 位置的 FactsProvider 包装 |
| `Sources/Sage/DT/DTWatcher.swift`（新） | DT 组轮询 actor + 可用性检测 |
| `Sources/Sage/Domain/ExecutionRecords.swift`（改） | `ReversibleOp` 新增 4 个 DT case |
| `Sources/Sage/Execution/Journal.swift`（改） | `rollback` 变 async，DT op 委托 `DTReverting` |
| `Sources/Sage/Execution/LocalActionExecutor.swift`（改） | DT 位置事件路由 + noteTemplate 令牌解析 |
| `Sources/Sage/Pipeline/SageCore.swift`（改） | 装配 DTActions/DTFactsAdapter |
| `Sources/Sage/Watchers/WatcherSupervisor.swift`（改） | 管理 DTWatcher 生命周期 |
| `Sources/Sage/ViewModels/AppModel.swift`（改） | `dtAvailable` 状态 |
| `Sources/Sage/ViewModels/JournalModel.swift`（改） | describe 覆盖新 op |
| `Sources/Sage/App/MenuBarView.swift`（改） | DT 未运行提示 |
| `Sources/Sage/Views/RuleEditorView.swift`（改） | DT 作用域/动作参数 UI |

---

### Task 1: AppleScript 基座（转义 + runner 协议 + 真实执行器）

**Files:**
- Create: `Sources/Sage/DT/AppleScriptRunning.swift`
- Test: `Tests/SageTests/DT/AppleScriptEscapeTests.swift`

**Interfaces:**
- Produces: `public protocol AppleScriptRunning: Sendable { func run(_ source: String) async throws -> String }`；`public enum DTError: LocalizedError`（`.notRunning` `.scriptFailed(String)` `.needsLocalFile`）；`public func appleScriptEscape(_ s: String) -> String`；`public struct NSAppleScriptRunner: AppleScriptRunning`；`public enum DTAvailability { public static var isRunningCheck: @Sendable () -> Bool }`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/DT/AppleScriptEscapeTests.swift
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
        // 若顺序错误，\" 会先变 \\" 再变 \\\\"（注入面）
        XCTAssertEqual(appleScriptEscape(#"\""#), #"\\\""#)
    }

    func test注入尝试被中和() {
        let hostile = #"x" & (do shell script "rm -rf ~") & ""#
        let escaped = appleScriptEscape(hostile)
        XCTAssertFalse(escaped.contains(#" & (do"#) && !escaped.contains(#"\""#))
        XCTAssertTrue(escaped.contains(#"\""#)) // 引号全部被转义
    }

    func testDTError中文消息() {
        XCTAssertEqual(DTError.notRunning.errorDescription, "DEVONthink 未运行，相关规则已暂停。")
        XCTAssertTrue(DTError.scriptFailed("boom").errorDescription!.contains("boom"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppleScriptEscapeTests`
Expected: FAIL（`appleScriptEscape`/`DTError` 未定义）

- [ ] **Step 3: 实现**

```swift
// Sources/Sage/DT/AppleScriptRunning.swift
import AppKit
import Foundation

/// AppleScript 字符串字面量转义（顺序关键：先反斜杠）。防注入，spec §5。
public func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

public enum DTError: LocalizedError, Equatable {
    case notRunning
    case scriptFailed(String)
    case needsLocalFile

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "DEVONthink 未运行，相关规则已暂停。"
        case .scriptFailed(let msg): return "DEVONthink 脚本执行失败：\(msg)"
        case .needsLocalFile: return "该 DEVONthink 动作需要本地文件来源。"
        }
    }
}

/// 执行一段 AppleScript 并返回字符串结果。真实实现走 NSAppleScript；测试注入 Fake。
public protocol AppleScriptRunning: Sendable {
    func run(_ source: String) async throws -> String
}

/// NSAppleScript 非线程安全：统一在主线程执行。
public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}
    public func run(_ source: String) async throws -> String {
        try await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                throw DTError.scriptFailed("脚本构造失败")
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知 AppleScript 错误"
                throw DTError.scriptFailed(msg)
            }
            return result.stringValue ?? ""
        }
    }
}

/// DT 是否在运行（DT3 与 DT4 bundle id 均检查）。测试可替换检查闭包。
public enum DTAvailability {
    public nonisolated(unsafe) static var isRunningCheck: @Sendable () -> Bool = {
        let ids = ["com.devon-technologies.think3", "com.devon-technologies.think"]
        return ids.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }
    public static func isRunning() -> Bool { isRunningCheck() }
}
```

**注意：** `nonisolated(unsafe) static var` 仅测试替换用；若 Swift 6 报并发错，改成 `DTActions`/`DTWatcher` 构造注入 `isRunning: @Sendable () -> Bool = DTAvailability.isRunning`（首选注入式，全局变量只是兜底）。实现时以注入参数为准也可，两处保持一致即可。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppleScriptEscapeTests`
Expected: PASS（4 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/DT Tests/SageTests/DT
git commit -m "feat(sage): AppleScript 基座——转义防注入、runner 协议与 DT 可用性"
```

---

### Task 2: DTScriptBuilder（全部脚本构造，纯函数）

**Files:**
- Create: `Sources/Sage/DT/DTScriptBuilder.swift`
- Test: `Tests/SageTests/DT/DTScriptBuilderTests.swift`

**Interfaces:**
- Consumes: `appleScriptEscape`（Task 1）。
- Produces（全部 `public static func … -> String`，`enum DTScriptBuilder`）：
  `importScript(filePath:database:groupPath:tags:note:)`、`renameScript(uuid:newName:)`（返回旧名）、`addTagsScript(uuid:tags:)`（返回旧标签，linefeed 连接）、`moveScript(uuid:toDatabase:toGroupPath:)`（返回 `旧库\t旧组`）、`deleteScript(uuid:)`、`setNameScript(uuid:name:)`、`setTagsScript(uuid:tags:)`、`listGroupScript(database:groupPath:)`（每行 `uuid\tmodToken`）、`factsScript(uuid:)`（`name\tkind\tsize\tcreatedISO\tmodifiedISO`）、`plainTextScript(uuid:)`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/DT/DTScriptBuilderTests.swift
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

    func test注入恶意路径被转义() {
        let s = DTScriptBuilder.deleteScript(uuid: #"x" -- do shell script "rm"#)
        // 恶意引号必须以 \" 形式出现，不得裸露成脚本结构
        XCTAssertTrue(s.contains(#"uuid "x\" -- do shell script \"rm""#))
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DTScriptBuilderTests`
Expected: FAIL（DTScriptBuilder 未定义）

- [ ] **Step 3: 实现**

```swift
// Sources/Sage/DT/DTScriptBuilder.swift
import Foundation

/// 全部 DT AppleScript 源码构造。纯函数、可注入字符串一律转义（spec §5）。
/// `tell application id "DNtp"` 对 DEVONthink 3 与 4 通用。
public enum DTScriptBuilder {
    private static func q(_ s: String) -> String { "\"\(appleScriptEscape(s))\"" }
    private static func list(_ items: [String]) -> String {
        "{" + items.map(q).joined(separator: ", ") + "}"
    }

    public static func importScript(filePath: String, database: String, groupPath: String,
                                    tags: [String], note: String?) -> String {
        var body = """
        set theGroup to get record at \(q(groupPath)) in database \(q(database))
        set theRecord to import \(q(filePath)) to theGroup
        """
        if !tags.isEmpty { body += "\nset tags of theRecord to \(list(tags))" }
        if let note, !note.isEmpty { body += "\nset comment of theRecord to \(q(note))" }
        body += "\nreturn uuid of theRecord"
        return wrap(body)
    }

    public static func renameScript(uuid: String, newName: String) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set oldName to name of theRecord
        set name of theRecord to \(q(newName))
        return oldName
        """)
    }

    public static func addTagsScript(uuid: String, tags: [String]) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set prev to tags of theRecord
        set tags of theRecord to prev & \(list(tags))
        set AppleScript's text item delimiters to linefeed
        return prev as string
        """)
    }

    public static func moveScript(uuid: String, toDatabase: String, toGroupPath: String) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set prevDB to name of database of theRecord
        set prevLoc to location of theRecord
        set destGroup to get record at \(q(toGroupPath)) in database \(q(toDatabase))
        move record theRecord to destGroup
        return prevDB & tab & prevLoc
        """)
    }

    public static func deleteScript(uuid: String) -> String {
        wrap("delete record (get record with uuid \(q(uuid)))")
    }

    public static func setNameScript(uuid: String, name: String) -> String {
        wrap("set name of (get record with uuid \(q(uuid))) to \(q(name))")
    }

    public static func setTagsScript(uuid: String, tags: [String]) -> String {
        wrap("set tags of (get record with uuid \(q(uuid))) to \(list(tags))")
    }

    public static func listGroupScript(database: String, groupPath: String) -> String {
        wrap("""
        set theGroup to get record at \(q(groupPath)) in database \(q(database))
        set out to ""
        repeat with r in (children of theGroup)
            set out to out & (uuid of r) & tab & (((modification date of r) as «class isot») as string) & linefeed
        end repeat
        return out
        """)
    }

    public static func factsScript(uuid: String) -> String {
        wrap("""
        set r to get record with uuid \(q(uuid))
        return (name of r) & tab & (kind of r) & tab & (size of r) & tab & (((creation date of r) as «class isot») as string) & tab & (((modification date of r) as «class isot») as string)
        """)
    }

    public static func plainTextScript(uuid: String) -> String {
        wrap("return plain text of (get record with uuid \(q(uuid)))")
    }

    private static func wrap(_ body: String) -> String {
        "tell application id \"DNtp\"\n\(body)\nend tell"
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DTScriptBuilderTests`
Expected: PASS（7 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/DT/DTScriptBuilder.swift Tests/SageTests/DT/DTScriptBuilderTests.swift
git commit -m "feat(sage): DTScriptBuilder 纯函数脚本构造（导入/改名/标签/移动/回滚/轮询/属性）"
```

---

### Task 3: ReversibleOp DT 扩展 + Journal 异步回滚委托

**Files:**
- Modify: `Sources/Sage/Domain/ExecutionRecords.swift`（ReversibleOp 加 4 case）
- Modify: `Sources/Sage/Execution/Journal.swift`（`rollback` 变 `async throws`；DT op 委托）
- Modify: `Sources/Sage/ViewModels/JournalModel.swift`（`describe` 覆盖新 case）
- Test: `Tests/SageTests/Execution/JournalDTRollbackTests.swift`

**Interfaces:**
- Produces：`ReversibleOp` 新 case：`.dtImported(uuid: String, database: String)`、`.dtRenamed(uuid: String, from: String, to: String)`、`.dtAddedTags([String], uuid: String, previous: [String])`、`.dtMoved(uuid: String, fromDatabase: String, fromGroup: String, toDatabase: String, toGroup: String)`；
  `public protocol DTReverting: Sendable { func revert(_ op: ReversibleOp) async throws }`（放 Journal.swift 顶部）；
  `Journal.init(directory:fileManager:dtReverter:)`（`dtReverter: (any DTReverting)? = nil`）；`Journal.rollback(id:)` 变 `async throws`（DT op 而 dtReverter 为 nil 时抛 `JournalError.rollbackFailed("DEVONthink 回滚不可用")`）。
- Consumes：无（Task 4 提供真实 DTReverting 实现）。

**注意：** `ReversibleOp` 是合成 Codable，加 case 向后兼容旧 journal.json；`JournalModel.describe`/`Journal.revert` 的 switch 是穷举——编译器会强制覆盖新 case。`Journal.rollback` 调用方（`JournalModel.rollback`）已 `await` actor 方法，签名加 async 不破坏调用点；但需确认 `try await`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/Execution/JournalDTRollbackTests.swift
import XCTest
@testable import Sage

private actor SpyReverter: DTReverting {
    var reverted: [ReversibleOp] = []
    func revert(_ op: ReversibleOp) async throws { reverted.append(op) }
    func all() -> [ReversibleOp] { reverted }
}

final class JournalDTRollbackTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJDT-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDT操作回滚委托给DTReverter并逆序() async throws {
        let spy = SpyReverter()
        let journal = Journal(directory: dir, dtReverter: spy)
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a.pdf",
                                ops: [.dtImported(uuid: "U1", database: "D"),
                                      .dtRenamed(uuid: "U1", from: "旧", to: "新")])
        try await journal.append(rec)
        try await journal.rollback(id: rec.id)
        let seen = await spy.all()
        XCTAssertEqual(seen.count, 2)
        // 逆序：先撤销改名，再撤销导入
        XCTAssertEqual(seen.first, .dtRenamed(uuid: "U1", from: "旧", to: "新"))
        XCTAssertEqual(seen.last, .dtImported(uuid: "U1", database: "D"))
        let remaining = try await journal.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test无DTReverter时DT操作回滚报错且记录保留() async throws {
        let journal = Journal(directory: dir)
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a", ops: [.dtImported(uuid: "U", database: "D")])
        try await journal.append(rec)
        do {
            try await journal.rollback(id: rec.id)
            XCTFail("应当抛错")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("DEVONthink"))
        }
        let remaining = try await journal.all()
        XCTAssertEqual(remaining.count, 1) // 失败不删记录
    }

    func testDT新case序列化往返() throws {
        let ops: [ReversibleOp] = [
            .dtImported(uuid: "U", database: "D"),
            .dtRenamed(uuid: "U", from: "a", to: "b"),
            .dtAddedTags(["x"], uuid: "U", previous: ["y"]),
            .dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/a", toDatabase: "D2", toGroup: "/b"),
        ]
        let data = try JSONEncoder().encode(ops)
        let back = try JSONDecoder().decode([ReversibleOp].self, from: data)
        XCTAssertEqual(back, ops)
    }

    func test日志描述覆盖DT操作() {
        XCTAssertTrue(JournalModel.describe(.dtImported(uuid: "U", database: "资料库")).contains("资料库"))
        XCTAssertTrue(JournalModel.describe(.dtRenamed(uuid: "U", from: "a", to: "b")).contains("b"))
        XCTAssertTrue(JournalModel.describe(.dtAddedTags(["t"], uuid: "U", previous: [])).contains("t"))
        XCTAssertTrue(JournalModel.describe(.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/a",
                                                     toDatabase: "D2", toGroup: "/b")).contains("/b"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter JournalDTRollbackTests`
Expected: 编译 FAIL（新 case 不存在）

- [ ] **Step 3: 实现**

`ExecutionRecords.swift` 的 `ReversibleOp` 追加：

```swift
    // DEVONthink 侧可逆操作（第 5 份计划）
    case dtImported(uuid: String, database: String)
    case dtRenamed(uuid: String, from: String, to: String)
    case dtAddedTags([String], uuid: String, previous: [String])
    case dtMoved(uuid: String, fromDatabase: String, fromGroup: String, toDatabase: String, toGroup: String)
```

`Journal.swift`：文件顶部加协议；init 加参数；rollback 改 async；revert 拆分本地/DT：

```swift
/// DT 操作的回滚执行（真实实现 Task 4 的 DTRollback；nil 表示 DT 回滚不可用）。
public protocol DTReverting: Sendable {
    func revert(_ op: ReversibleOp) async throws
}
```

```swift
    private let dtReverter: (any DTReverting)?

    public init(directory: URL, fileManager: FileManager = .default,
                dtReverter: (any DTReverting)? = nil) {
        self.fileURL = directory.appendingPathComponent("journal.json")
        self.fileManager = fileManager
        self.dtReverter = dtReverter
    }

    public func rollback(id: UUID) async throws {
        var file = try load()
        guard let index = file.records.firstIndex(where: { $0.id == id }) else {
            throw JournalError.recordNotFound
        }
        let record = file.records[index]
        for op in record.ops.reversed() {
            switch op {
            case .dtImported, .dtRenamed, .dtAddedTags, .dtMoved:
                guard let dtReverter else {
                    throw JournalError.rollbackFailed("DEVONthink 回滚不可用")
                }
                try await dtReverter.revert(op)
            default:
                try revert(op)
            }
        }
        file.records.remove(at: index)
        try save(file)
    }
```

（原 `revert(_:)` 保持只处理本地 5 个 case，DT case 分支加 `fatalError` 不可达？——不：保持穷举安全，DT case 在 revert 里 `throw JournalError.rollbackFailed("内部错误：DT 操作应由 dtReverter 处理")`。）

`JournalModel.describe` 追加：

```swift
        case .dtImported(_, let database): return "已导入 DEVONthink：\(database)（回滚=删除该记录）"
        case .dtRenamed(_, let from, let to): return "DEVONthink 内 \(from) → \(to)"
        case .dtAddedTags(let tags, _, _): return "DEVONthink 加标签 \(tags.joined(separator: "、"))"
        case .dtMoved(_, _, let fromGroup, _, let toGroup): return "DEVONthink \(fromGroup) → \(toGroup)"
```

同时检查 `JournalModel.rollback` 调用点：`try await journal.rollback(id:)` 已是 await——只需确认编译。

- [ ] **Step 4: 全量回归**

Run: `swift test --filter SageTests`
Expected: 全绿（含新 4 测试；旧 Journal 测试若直接调 `rollback` 需加 `await`）

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): ReversibleOp DT 扩展与 Journal 异步回滚委托"
```

---

### Task 4: DTActions 执行器 + DTRollback + LocalActionExecutor 路由

**Files:**
- Create: `Sources/Sage/DT/DTActions.swift`
- Modify: `Sources/Sage/Execution/LocalActionExecutor.swift:70-72`（DT 位置路由 + note 模板解析）
- Modify: `Sources/Sage/Execution/ActionExecuting.swift`（删除 `UnimplementedDTActionExecutor`？**保留**——测试与默认参数仍用）
- Test: `Tests/SageTests/DT/DTActionsTests.swift`

**Interfaces:**
- Consumes: `AppleScriptRunning`、`DTScriptBuilder`、`DTError`（Task 1/2）；`DTActionExecutor`（既有：`func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp]`）；`DTReverting`（Task 3）。
- Produces: `public struct DTActions: DTActionExecutor, DTReverting`，`init(runner: any AppleScriptRunning = NSAppleScriptRunner(), isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning)`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/DT/DTActionsTests.swift
import XCTest
@testable import Sage

/// 记录收到的脚本并按序返回预设结果。
private final class FakeRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String]
    private(set) var scripts: [String] = []
    init(results: [String]) { self.results = results }
    func run(_ source: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        scripts.append(source)
        return results.isEmpty ? "" : results.removeFirst()
    }
}

final class DTActionsTests: XCTestCase {
    func test导入返回uuid并产出可逆操作() async throws {
        let runner = FakeRunner(results: ["UUID-42"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(
            .dtImport(database: "D", groupPath: "/g", tags: ["t"], noteTemplate: "备注"),
            at: .local(path: "/tmp/a.pdf"))
        XCTAssertEqual(ops, [.dtImported(uuid: "UUID-42", database: "D")])
        XCTAssertTrue(runner.scripts[0].contains(#"import "/tmp/a.pdf""#))
    }

    func test导入需要本地来源() async {
        let dt = DTActions(runner: FakeRunner(results: []), isRunning: { true })
        do {
            _ = try await dt.execute(.dtImport(database: "D", groupPath: "/g", tags: [], noteTemplate: nil),
                                     at: .devonthink(uuid: "U", database: "D", groupPath: "/g"))
            XCTFail("应当抛错")
        } catch { XCTAssertEqual(error as? DTError, .needsLocalFile) }
    }

    func testDT内改名记录旧名() async throws {
        let runner = FakeRunner(results: ["旧名"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtRename(template: "新名"),
                                       at: .devonthink(uuid: "U", database: "D", groupPath: "/g"))
        XCTAssertEqual(ops, [.dtRenamed(uuid: "U", from: "旧名", to: "新名")])
    }

    func testDT加标签记录旧标签() async throws {
        let runner = FakeRunner(results: ["a\nb"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtAddTags(["c"]),
                                       at: .devonthink(uuid: "U", database: "D", groupPath: "/g"))
        XCTAssertEqual(ops, [.dtAddedTags(["c"], uuid: "U", previous: ["a", "b"])])
    }

    func testDT移动记录旧位置() async throws {
        let runner = FakeRunner(results: ["D1\t/inbox"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let ops = try await dt.execute(.dtMoveToGroup(database: "D2", groupPath: "/done"),
                                       at: .devonthink(uuid: "U", database: "D1", groupPath: "/inbox"))
        XCTAssertEqual(ops, [.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/inbox",
                                      toDatabase: "D2", toGroup: "/done")])
    }

    func testDT未运行抛notRunning() async {
        let dt = DTActions(runner: FakeRunner(results: []), isRunning: { false })
        do {
            _ = try await dt.execute(.dtAddTags(["x"]),
                                     at: .devonthink(uuid: "U", database: "D", groupPath: "/g"))
            XCTFail("应当抛错")
        } catch { XCTAssertEqual(error as? DTError, .notRunning) }
    }

    func test回滚导入即删除记录() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtImported(uuid: "U", database: "D"))
        XCTAssertTrue(runner.scripts[0].contains(#"delete record (get record with uuid "U")"#))
    }

    func test回滚改名恢复旧名() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtRenamed(uuid: "U", from: "旧", to: "新"))
        XCTAssertTrue(runner.scripts[0].contains(#"set name of (get record with uuid "U") to "旧""#))
    }

    func test回滚标签恢复previous() async throws {
        let runner = FakeRunner(results: [""])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtAddedTags(["c"], uuid: "U", previous: ["a"]))
        XCTAssertTrue(runner.scripts[0].contains(#"set tags of (get record with uuid "U") to {"a"}"#))
    }

    func test回滚移动搬回原组() async throws {
        let runner = FakeRunner(results: ["D2\t/done"])
        let dt = DTActions(runner: runner, isRunning: { true })
        try await dt.revert(.dtMoved(uuid: "U", fromDatabase: "D1", fromGroup: "/inbox",
                                     toDatabase: "D2", toGroup: "/done"))
        XCTAssertTrue(runner.scripts[0].contains(#"get record at "/inbox" in database "D1""#))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DTActionsTests`
Expected: 编译 FAIL（DTActions 未定义）

- [ ] **Step 3: 实现 DTActions**

```swift
// Sources/Sage/DT/DTActions.swift
import Foundation

/// DT 动作真实执行器 + DT 回滚（spec §5）。逻辑经 FakeRunner 测试；真实执行手动验证。
public struct DTActions: DTActionExecutor, DTReverting {
    private let runner: any AppleScriptRunning
    private let isRunning: @Sendable () -> Bool

    public init(runner: any AppleScriptRunning = NSAppleScriptRunner(),
                isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning) {
        self.runner = runner
        self.isRunning = isRunning
    }

    public func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp] {
        guard isRunning() else { throw DTError.notRunning }
        switch action {
        case .dtImport(let database, let groupPath, let tags, let noteTemplate):
            guard case .local(let path) = location else { throw DTError.needsLocalFile }
            let uuid = try await runner.run(DTScriptBuilder.importScript(
                filePath: path, database: database, groupPath: groupPath,
                tags: tags, note: noteTemplate))
            return [.dtImported(uuid: uuid, database: database)]

        case .dtRename(let template):
            let uuid = try recordUUID(of: location)
            let oldName = try await runner.run(DTScriptBuilder.renameScript(uuid: uuid, newName: template))
            return [.dtRenamed(uuid: uuid, from: oldName, to: template)]

        case .dtAddTags(let tags):
            let uuid = try recordUUID(of: location)
            let prevRaw = try await runner.run(DTScriptBuilder.addTagsScript(uuid: uuid, tags: tags))
            let previous = prevRaw.split(separator: "\n").map(String.init)
            return [.dtAddedTags(tags, uuid: uuid, previous: previous)]

        case .dtMoveToGroup(let database, let groupPath):
            let uuid = try recordUUID(of: location)
            let prevRaw = try await runner.run(DTScriptBuilder.moveScript(
                uuid: uuid, toDatabase: database, toGroupPath: groupPath))
            let parts = prevRaw.split(separator: "\t", maxSplits: 1).map(String.init)
            let fromDB = parts.first ?? ""
            let fromGroup = parts.count > 1 ? parts[1] : ""
            return [.dtMoved(uuid: uuid, fromDatabase: fromDB, fromGroup: fromGroup,
                             toDatabase: database, toGroup: groupPath)]

        default:
            throw ActionExecutionError.unsupportedAction("非 DEVONthink 动作")
        }
    }

    public func revert(_ op: ReversibleOp) async throws {
        guard isRunning() else { throw DTError.notRunning }
        switch op {
        case .dtImported(let uuid, _):
            _ = try await runner.run(DTScriptBuilder.deleteScript(uuid: uuid))
        case .dtRenamed(let uuid, let from, _):
            _ = try await runner.run(DTScriptBuilder.setNameScript(uuid: uuid, name: from))
        case .dtAddedTags(_, let uuid, let previous):
            _ = try await runner.run(DTScriptBuilder.setTagsScript(uuid: uuid, tags: previous))
        case .dtMoved(let uuid, let fromDatabase, let fromGroup, _, _):
            _ = try await runner.run(DTScriptBuilder.moveScript(
                uuid: uuid, toDatabase: fromDatabase, toGroupPath: fromGroup))
        default:
            throw JournalError.rollbackFailed("非 DEVONthink 操作不应到达 DTActions.revert")
        }
    }

    private func recordUUID(of location: FileLocation) throws -> String {
        guard case .devonthink(let uuid, _, _) = location else { throw DTError.needsLocalFile }
        return uuid
    }
}
```

**说明：** `.dtRename` 对 DT 内条目作用；对本地文件（先导入再改名）的组合流由 LocalActionExecutor 顺序执行——导入后位置仍是本地，dtRename 需要 DT 位置：此组合在 Step 4 路由里处理（导入后把返回 uuid 传给后续 DT 动作）。

- [ ] **Step 4: LocalActionExecutor DT 路由**

修改 `execute` 中 DT 分支（`LocalActionExecutor.swift:70-72`）——支持三件事：①DT 位置事件直接分派；②本地文件导入后，后续 DT 动作作用于新导入的记录；③`noteTemplate` 的令牌用当前 metadata 解析：

```swift
                case .dtImport(let database, let groupPath, let tags, let noteTemplate):
                    let resolvedNote = noteTemplate.map { resolveNote($0, metadata: metadata) }
                    let dtOps = try await dtExecutor.execute(
                        .dtImport(database: database, groupPath: groupPath, tags: tags, noteTemplate: resolvedNote),
                        at: .local(path: currentPath))
                    ops.append(contentsOf: dtOps)
                    // 记住导入产生的 DT 记录，供同一动作序列的后续 DT 动作作用
                    if case .dtImported(let uuid, let db)? = dtOps.first {
                        currentDTLocation = .devonthink(uuid: uuid, database: db, groupPath: groupPath)
                    }
                case .dtRename, .dtAddTags, .dtMoveToGroup:
                    let target: FileLocation
                    if case .devonthink = startLocation { target = startLocation }
                    else if let currentDTLocation { target = currentDTLocation }
                    else { throw ActionExecutionError.unsupportedAction("该 DEVONthink 动作需要先导入或作用于 DT 条目") }
                    let dtOps = try await dtExecutor.execute(action, at: target)
                    ops.append(contentsOf: dtOps)
```

同时：
1. `execute` 顶部 `guard case .local(var currentPath)` 需放宽：DT 位置事件允许进入，但只允许 DT 动作。改为：

```swift
        var currentPath: String
        var currentDTLocation: FileLocation?
        switch startLocation {
        case .local(let p): currentPath = p
        case .devonthink:
            currentPath = ""            // DT 位置事件不允许本地文件动作
            currentDTLocation = startLocation
        }
```

并在所有本地动作分支（moveTo/copyTo/rename/llmRename/addFinderTags/moveToTrash）之前统一守卫：

```swift
                case .moveTo, .copyTo, .rename, .llmRename, .addFinderTags, .moveToTrash:
                    guard case .local = startLocation else { throw ActionExecutionError.notLocalFile }
```

（实现方式自由：可在各 case 内首行守卫，或用上面的聚合 case 先行拦截再二次 switch——以可读性与编译通过为准，语义不变：**DT 位置事件 + 本地动作 = notLocalFile 错误**。）
2. `llmExtractMetadata` 分支对 DT 位置：`metadata = try await metadataProvider.metadata(for: startLocation)`（用事件位置而非 currentPath）。
3. note 模板解析加私有助手（复用 TemplateResolver 令牌语义，但备注不是文件名不做清洗，只做 `{summary}`/`{title}`/`{category}` 直替）：

```swift
    private func resolveNote(_ template: String, metadata: ExtractedMetadata) -> String {
        template
            .replacingOccurrences(of: "{summary}", with: metadata.summary ?? "")
            .replacingOccurrences(of: "{title}", with: metadata.title ?? "")
            .replacingOccurrences(of: "{category}", with: metadata.category ?? "")
    }
```

再补集成测试（追加到 `Tests/SageTests/DT/DTActionsTests.swift`）：

```swift
    func test本地导入后续DT动作作用于新记录() async throws {
        let runner = FakeRunner(results: ["NEW-UUID", "旧名"])
        let dt = DTActions(runner: runner, isRunning: { true })
        let executor = LocalActionExecutor(metadataProvider: NullMetadataProvider(), dtExecutor: dt)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dtchain-\(UUID()).pdf")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ops = try await executor.run(
            actions: [.dtImport(database: "D", groupPath: "/g", tags: [], noteTemplate: nil),
                      .dtRename(template: "新名")],
            on: .local(path: tmp.path))
        XCTAssertEqual(ops, [.dtImported(uuid: "NEW-UUID", database: "D"),
                             .dtRenamed(uuid: "NEW-UUID", from: "旧名", to: "新名")])
        XCTAssertTrue(runner.scripts[1].contains(#"uuid "NEW-UUID""#))
    }

    func testDT位置事件的本地动作被拒绝() async {
        let executor = LocalActionExecutor(metadataProvider: NullMetadataProvider(),
                                           dtExecutor: DTActions(runner: FakeRunner(results: []), isRunning: { true }))
        do {
            _ = try await executor.run(actions: [.rename(template: "x")],
                                       on: .devonthink(uuid: "U", database: "D", groupPath: "/g"))
            XCTFail("应当抛错")
        } catch { /* notLocalFile */ }
    }
```

`NullMetadataProvider` 若测试目录尚无，则在本测试文件定义：

```swift
private struct NullMetadataProvider: MetadataProviding {
    func metadata(for location: FileLocation) async throws -> ExtractedMetadata { ExtractedMetadata() }
}
```

（若 `Tests/SageTests` 已有同名 helper，直接复用勿重复定义——先 `grep -rn "MetadataProviding" Tests/SageTests/`。）

- [ ] **Step 5: 全量回归**

Run: `swift test --filter SageTests`
Expected: 全绿（既有 LocalActionExecutor 测试不回归——本地事件路径行为不变）

- [ ] **Step 6: Commit**

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): DTActions 真实执行器与回滚；LocalActionExecutor DT 路由与导入链"
```

---

### Task 5: DTFactsAdapter（DT 条目的 FileFacts）

**Files:**
- Create: `Sources/Sage/DT/DTFactsAdapter.swift`
- Test: `Tests/SageTests/DT/DTFactsAdapterTests.swift`

**Interfaces:**
- Consumes: `FactsProvider`（既有 4 方法协议）、`AppleScriptRunning`、`DTScriptBuilder`、`CheapFacts`/`ExtractedFacts`（`CheapFacts(name:fileExtension:sizeBytes:createdAt:modifiedAt:utType:)`、`ExtractedFacts(text:contentHash:isDuplicate:captureDate:sourceURL:)` —— 以 `Sources/Sage/Domain/FileFacts.swift` 实际 memberwise init 为准，先读该文件）。
- Produces: `public struct DTFactsAdapter: FactsProvider`，`init(local: any FactsProvider, runner: any AppleScriptRunning = NSAppleScriptRunner())`——`.local` 位置全部转发 `local`；`.devonthink` 位置：cheap 由 `factsScript` 解析，extracted 由 `plainTextScript` + CryptoKit SHA256 哈希，`belongsTo`/`matchesDescription` 转发 `local`（LLM 判定只依赖 extractedFacts 文本——注意：`ExtractionProvider.belongsTo` 内部会再调自身的 `extractedFacts`，对 DT 位置会失败）。

**关键设计：** `ExtractionProvider.belongsTo(category:at:)` 内部调用自己的 `extractedFacts`，对 `.devonthink` 位置会抛错。因此 DTFactsAdapter 不能简单转发 LLM 两方法——需要 `ExtractionProvider` 暴露一个「用外部提供的文本做语义判定」的入口。检查 `ExtractionProvider` 现有代码：`belongsTo` 的实现是 `extractedFacts → LLMPrompts.belongsTo(category:text:) → gateway`。**方案：给 `ExtractionProvider` 加 `public func belongsTo(category: String, text: String, cacheKey: String) async throws -> SemanticVerdict`（把现方法的后半段抽出复用），`matchesDescription` 同理**；DTFactsAdapter 对 DT 位置先取自身 extractedFacts（DT 纯文本）再调这两个 text 入口。

- [ ] **Step 1: 先读现文件**

Read `Sources/Sage/Domain/FileFacts.swift`（CheapFacts/ExtractedFacts 的实际字段与 init）与 `Sources/Sage/Extraction/ExtractionProvider.swift`（belongsTo/matchesDescription 全文），按实际签名校准下方代码。

- [ ] **Step 2: 失败测试**

```swift
// Tests/SageTests/DT/DTFactsAdapterTests.swift
import XCTest
@testable import Sage

private final class ScriptedRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var byContains: [(needle: String, result: String)]
    init(_ byContains: [(String, String)]) { self.byContains = byContains }
    func run(_ source: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        for (needle, result) in byContains where source.contains(needle) { return result }
        throw DTError.scriptFailed("unexpected script: \(source)")
    }
}

final class DTFactsAdapterTests: XCTestCase {
    private let dtLoc = FileLocation.devonthink(uuid: "U", database: "D", groupPath: "/g")

    func testDT位置cheapFacts来自记录属性() async throws {
        let runner = ScriptedRunner([
            ("size of r", "发票 2026.pdf\tPDF 文稿\t2048\t2026-07-01T08:00:00\t2026-07-02T09:30:00"),
        ])
        let adapter = DTFactsAdapter(local: ThrowingFactsProvider(), runner: runner)
        let facts = try await adapter.cheapFacts(for: dtLoc)
        XCTAssertEqual(facts.name, "发票 2026")
        XCTAssertEqual(facts.fileExtension, "pdf")
        XCTAssertEqual(facts.sizeBytes, 2048)
        XCTAssertNotNil(facts.createdAt)
        XCTAssertNotNil(facts.modifiedAt)
    }

    func testDT位置extractedFacts含纯文本与哈希() async throws {
        let runner = ScriptedRunner([("plain text of", "正文内容")])
        let adapter = DTFactsAdapter(local: ThrowingFactsProvider(), runner: runner)
        let facts = try await adapter.extractedFacts(for: dtLoc)
        XCTAssertEqual(facts.text, "正文内容")
        XCTAssertNotNil(facts.contentHash)
    }

    func test本地位置全部转发内层provider() async throws {
        let spy = SpyFactsProvider()
        let adapter = DTFactsAdapter(local: spy, runner: ScriptedRunner([]))
        _ = try? await adapter.cheapFacts(for: .local(path: "/a"))
        let called = await spy.cheapCalled
        XCTAssertTrue(called)
    }
}

/// 本地被误调用时立刻暴露。
private struct ThrowingFactsProvider: FactsProvider {
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts { throw DTError.scriptFailed("不应调用") }
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts { throw DTError.scriptFailed("不应调用") }
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("不应调用") }
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("不应调用") }
}

private actor SpyFactsProvider: FactsProvider {
    var cheapCalled = false
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts { cheapCalled = true; throw DTError.scriptFailed("stub") }
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts { throw DTError.scriptFailed("stub") }
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("stub") }
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict { throw DTError.scriptFailed("stub") }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter DTFactsAdapterTests`
Expected: 编译 FAIL

- [ ] **Step 4: 实现**

```swift
// Sources/Sage/DT/DTFactsAdapter.swift
import CryptoKit
import Foundation

/// FactsProvider 包装：.devonthink 位置由 DT 记录属性 + 纯文本导出填充（spec §5）；
/// .local 位置全部转发内层 provider。
public struct DTFactsAdapter: FactsProvider {
    private let local: any FactsProvider
    private let runner: any AppleScriptRunning

    /// DT «class isot» 日期形如 2026-07-01T08:00:00（本地时区、无时差后缀）。
    private static let isot: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(local: any FactsProvider, runner: any AppleScriptRunning = NSAppleScriptRunner()) {
        self.local = local
        self.runner = runner
    }

    public func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        guard case .devonthink(let uuid, _, _) = location else {
            return try await local.cheapFacts(for: location)
        }
        let raw = try await runner.run(DTScriptBuilder.factsScript(uuid: uuid))
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 5 else { throw DTError.scriptFailed("记录属性格式异常：\(raw)") }
        let fullName = parts[0]
        let ext = (fullName as NSString).pathExtension.lowercased()
        let stem = ext.isEmpty ? fullName : (fullName as NSString).deletingPathExtension
        return CheapFacts(name: stem, fileExtension: ext,
                          sizeBytes: Int64(parts[2]) ?? 0,
                          createdAt: Self.isot.date(from: parts[3]),
                          modifiedAt: Self.isot.date(from: parts[4]),
                          utType: nil)
    }

    public func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        guard case .devonthink(let uuid, _, _) = location else {
            return try await local.extractedFacts(for: location)
        }
        let text = try await runner.run(DTScriptBuilder.plainTextScript(uuid: uuid))
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        var facts = ExtractedFacts()
        facts.text = text
        facts.contentHash = hash
        return facts
    }

    public func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
        guard case .devonthink = location else { return try await local.belongsTo(category: category, at: location) }
        let facts = try await extractedFacts(for: location)
        return try await semantic(local).belongsTo(category: category, text: facts.text ?? "",
                                                   cacheKey: facts.contentHash ?? "dt:nohash")
    }

    public func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
        guard case .devonthink = location else { return try await local.matchesDescription(description, at: location) }
        let facts = try await extractedFacts(for: location)
        return try await semantic(local).matchesDescription(description, text: facts.text ?? "",
                                                            cacheKey: facts.contentHash ?? "dt:nohash")
    }

    private func semantic(_ provider: any FactsProvider) throws -> ExtractionProvider {
        guard let extraction = provider as? ExtractionProvider else {
            throw DTError.scriptFailed("DT 位置的 LLM 条件需要 ExtractionProvider")
        }
        return extraction
    }
}
```

同时在 `ExtractionProvider` 抽出 text 入口（把现有 `belongsTo(category:at:)` 与 `matchesDescription(_:at:)` 的「已有文本之后」半段抽成）：

```swift
    /// 用外部提供的文本做语义判定（DT 位置经 DTFactsAdapter 调用）。
    public func belongsTo(category: String, text: String, cacheKey: String) async throws -> SemanticVerdict {
        // 现 belongsTo(category:at:) 中 request 构造 + gateway 调用 + 缓存逻辑移到这里；
        // 原方法改为 extractedFacts → 调本方法。缓存 key 沿用现有 hash 组合方式。
    }
    public func matchesDescription(_ description: String, text: String, cacheKey: String) async throws -> SemanticVerdict {
        // 同上抽取
    }
```

（**照现文件实际代码搬移，勿凭空重写**；ExtractionProvider 既有测试必须保持全绿。）

- [ ] **Step 5: 全量回归**

Run: `swift test --filter SageTests`
Expected: 全绿

- [ ] **Step 6: Commit**

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): DTFactsAdapter——DT 条目属性/纯文本充当 FileFacts，LLM 判定走文本入口"
```

---

### Task 6: DTWatcher 轮询 + 未运行暂停

**Files:**
- Create: `Sources/Sage/DT/DTWatcher.swift`
- Test: `Tests/SageTests/DT/DTWatcherTests.swift`

**Interfaces:**
- Consumes: `AppleScriptRunning`、`DTScriptBuilder.listGroupScript`、`FileEvent`/`EventSource.dtWatch`、`RuleScope.devonthink`。
- Produces:
  ```swift
  public struct DTWatchedGroup: Sendable, Equatable, Hashable { public let database: String; public let groupPath: String }
  public actor DTWatcher {
      public init(groups: [DTWatchedGroup], runner: any AppleScriptRunning = NSAppleScriptRunner(),
                  pollInterval: Duration = .seconds(60),
                  isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning,
                  onEvent: @escaping @Sendable (FileEvent) async -> Void,
                  onAvailabilityChange: (@Sendable (Bool) async -> Void)? = nil)
      public nonisolated static func watchedGroups(rules: [Rule]) -> [DTWatchedGroup]  // 启用+automatic 规则的 DT 作用域去重
      public func start()      // 启动轮询循环（幂等：已启动则忽略）
      public func stop()
      public func pollOnce() async  // 拆出的单轮轮询，测试直接调用（不起循环）
  }
  ```

**语义：** 每轮：`isRunning()` 为 false → 跳过轮询并回调 `onAvailabilityChange(false)`（仅状态变化时回调一次，不弹错误，spec §5/§8）；恢复后回调 `true` 并继续。对每个 group 执行 listGroupScript，解析 `uuid\tmodToken` 行集；与上轮「已见 {uuid: modToken}」对比：新 uuid 或 modToken 变化 → 产出 `FileEvent(location: .devonthink(uuid:database:groupPath:), source: .dtWatch(database:groupPath:))`。**首轮只建基线不发事件**（避免启动风暴，与 FolderWatcher 语义一致——实现前 grep FolderWatcher 确认其首轮语义，保持一致）。脚本失败：该轮静默跳过（记 NSLog），不中断循环。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/DT/DTWatcherTests.swift
import XCTest
@testable import Sage

private final class SequenceRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [String]
    init(rounds: [String]) { self.rounds = rounds }
    func run(_ source: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        return rounds.isEmpty ? "" : rounds.removeFirst()
    }
}

private actor EventSink {
    var events: [FileEvent] = []
    func add(_ e: FileEvent) { events.append(e) }
    func all() -> [FileEvent] { events }
}

final class DTWatcherTests: XCTestCase {
    private let g = DTWatchedGroup(database: "D", groupPath: "/inbox")

    func test首轮建基线不发事件_新条目次轮发事件() async throws {
        let runner = SequenceRunner(rounds: [
            "U1\t2026-07-01T00:00:00\n",                      // 第 1 轮：基线
            "U1\t2026-07-01T00:00:00\nU2\t2026-07-02T00:00:00\n", // 第 2 轮：新增 U2
        ])
        let sink = EventSink()
        let watcher = DTWatcher(groups: [g], runner: runner, isRunning: { true },
                                onEvent: { await sink.add($0) })
        await watcher.pollOnce()
        await watcher.pollOnce()
        let events = await sink.all()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].location, .devonthink(uuid: "U2", database: "D", groupPath: "/inbox"))
        XCTAssertEqual(events[0].source, .dtWatch(database: "D", groupPath: "/inbox"))
    }

    func test修改时间变化视为新事件() async throws {
        let runner = SequenceRunner(rounds: [
            "U1\tt1\n",
            "U1\tt2\n",
        ])
        let sink = EventSink()
        let watcher = DTWatcher(groups: [g], runner: runner, isRunning: { true },
                                onEvent: { await sink.add($0) })
        await watcher.pollOnce()
        await watcher.pollOnce()
        let events = await sink.all()
        XCTAssertEqual(events.count, 1)
    }

    func testDT未运行跳过轮询且状态回调一次() async throws {
        let flag = LockedBox(false)
        let statuses = LockedArray<Bool>()
        let watcher = DTWatcher(groups: [g], runner: SequenceRunner(rounds: []),
                                isRunning: { flag.get() },
                                onEvent: { _ in },
                                onAvailabilityChange: { statuses.append($0) })
        await watcher.pollOnce()   // 未运行 → false
        await watcher.pollOnce()   // 仍未运行 → 不重复回调
        flag.set(true)
        await watcher.pollOnce()   // 恢复 → true
        XCTAssertEqual(statuses.all(), [false, true])
    }

    func test从规则推导去重DT组() {
        let r1 = Rule(id: UUID(), name: "a", enabled: true,
                      scopes: [.devonthink(database: "D", groupPath: "/x")], trigger: .automatic,
                      conditionLogic: .all, conditions: [], actions: [.dtAddTags(["t"])], executionMode: .automatic)
        var r2 = r1; r2.id = UUID(); r2.trigger = .manualOnly       // 手动规则不监控
        var r3 = r1; r3.id = UUID(); r3.enabled = false             // 停用不监控
        var r4 = r1; r4.id = UUID()                                 // 同组去重
        let groups = DTWatcher.watchedGroups(rules: [r1, r2, r3, r4])
        XCTAssertEqual(groups, [DTWatchedGroup(database: "D", groupPath: "/x")])
    }
}

// 线程安全测试助手（同文件底部）：
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); defer { lock.unlock() }; value = v }
}
private final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func append(_ v: T) { lock.lock(); defer { lock.unlock() }; items.append(v) }
    func all() -> [T] { lock.lock(); defer { lock.unlock() }; return items }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DTWatcherTests`
Expected: 编译 FAIL

- [ ] **Step 3: 实现**

```swift
// Sources/Sage/DT/DTWatcher.swift
import Foundation

public struct DTWatchedGroup: Sendable, Equatable, Hashable {
    public let database: String
    public let groupPath: String
    public init(database: String, groupPath: String) {
        self.database = database; self.groupPath = groupPath
    }
}

/// DT 组轮询监控（spec §5）：以「已见 uuid → 修改时间 token」识别新/变条目。
/// DT 未运行：跳过轮询、回调可用性变化、不弹错误；恢复后自动续。
public actor DTWatcher {
    private let groups: [DTWatchedGroup]
    private let runner: any AppleScriptRunning
    private let pollInterval: Duration
    private let isRunning: @Sendable () -> Bool
    private let onEvent: @Sendable (FileEvent) async -> Void
    private let onAvailabilityChange: (@Sendable (Bool) async -> Void)?

    private var seen: [DTWatchedGroup: [String: String]] = [:]  // group → uuid → modToken
    private var baselineBuilt: Set<DTWatchedGroup> = []
    private var lastAvailability: Bool?
    private var loopTask: Task<Void, Never>?

    public init(groups: [DTWatchedGroup], runner: any AppleScriptRunning = NSAppleScriptRunner(),
                pollInterval: Duration = .seconds(60),
                isRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning,
                onEvent: @escaping @Sendable (FileEvent) async -> Void,
                onAvailabilityChange: (@Sendable (Bool) async -> Void)? = nil) {
        self.groups = groups
        self.runner = runner
        self.pollInterval = pollInterval
        self.isRunning = isRunning
        self.onEvent = onEvent
        self.onAvailabilityChange = onAvailabilityChange
    }

    /// 启用+自动触发规则声明的 DT 作用域，去重。
    public nonisolated static func watchedGroups(rules: [Rule]) -> [DTWatchedGroup] {
        var out: [DTWatchedGroup] = []
        for rule in rules where rule.enabled && rule.trigger == .automatic {
            for scope in rule.scopes {
                if case .devonthink(let db, let group) = scope {
                    let g = DTWatchedGroup(database: db, groupPath: group)
                    if !out.contains(g) { out.append(g) }
                }
            }
        }
        return out
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [pollInterval] in
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public func pollOnce() async {
        let available = isRunning()
        if available != lastAvailability {
            lastAvailability = available
            await onAvailabilityChange?(available)
        }
        guard available else { return }

        for group in groups {
            let raw: String
            do { raw = try await runner.run(DTScriptBuilder.listGroupScript(database: group.database, groupPath: group.groupPath)) }
            catch { NSLog("DTWatcher 轮询失败（\(group.database)\(group.groupPath)）：\(error.localizedDescription)"); continue }

            var current: [String: String] = [:]
            for line in raw.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                current[parts[0]] = parts[1]
            }

            defer { seen[group] = current }
            guard baselineBuilt.contains(group) else {
                baselineBuilt.insert(group)   // 首轮只建基线，不发事件
                continue
            }
            let previous = seen[group] ?? [:]
            for (uuid, token) in current where previous[uuid] != token {
                await onEvent(FileEvent(
                    location: .devonthink(uuid: uuid, database: group.database, groupPath: group.groupPath),
                    source: .dtWatch(database: group.database, groupPath: group.groupPath)))
            }
        }
    }
}
```

（`FileEvent` 的实际 init 以 `Sources/Sage/Domain/FileEvent.swift` 为准——现有代码用 `FileEvent(location:source:)`。）

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `swift test --filter DTWatcherTests` → PASS（4 tests）
Run: `swift test --filter SageTests` → 全绿

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/DT/DTWatcher.swift Tests/SageTests/DT/DTWatcherTests.swift
git commit -m "feat(sage): DTWatcher 轮询监控——uuid+修改时间识别新条目，未运行暂停"
```

---

### Task 7: 装配——SageCore、WatcherSupervisor、AppModel、菜单栏提示

**Files:**
- Modify: `Sources/Sage/Pipeline/SageCore.swift`（DTActions/DTFactsAdapter/dtReverter 接线）
- Modify: `Sources/Sage/Watchers/WatcherSupervisor.swift`（DTWatcher 生命周期）
- Modify: `Sources/Sage/ViewModels/AppModel.swift`（`dtAvailable` 状态 + supervisor 传递）
- Modify: `Sources/Sage/App/MenuBarView.swift`（DT 未运行提示行）
- Test: `Tests/SageTests/Watchers/WatcherSupervisorDTTests.swift`

**Interfaces:**
- Consumes: Task 4/5/6 全部产出；`WatcherSupervisor.start/stopAll/restart(rules:)`（既有）；`AppModel`（既有）。
- Produces: `WatcherSupervisor.init(coordinator:dtRunner:dtIsRunning:onDTAvailabilityChange:)`（后三个参数有默认值，测试可注入）；`AppModel.dtAvailable: Bool`（默认 true，仅 DT 组被监控且 DT 未运行时变 false）。

- [ ] **Step 1: 失败测试**

```swift
// Tests/SageTests/Watchers/WatcherSupervisorDTTests.swift
import XCTest
@testable import Sage

final class WatcherSupervisorDTTests: XCTestCase {
    func testDT规则触发DTWatcher启动与停止不崩溃() async throws {
        // 冒烟：带 DT 作用域的规则 restart/stopAll 生命周期正常（runner 永不被真实调用——isRunning=false 跳过轮询）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageWS-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        let core = SageCore.makeDefault(supportDirectory: dir, gateway: gateway)
        let supervisor = WatcherSupervisor(coordinator: core.coordinator, dtIsRunning: { false })
        let rule = Rule(id: UUID(), name: "dt", enabled: true,
                        scopes: [.devonthink(database: "D", groupPath: "/g")], trigger: .automatic,
                        conditionLogic: .all, conditions: [], actions: [.dtAddTags(["t"])],
                        executionMode: .automatic)
        await supervisor.restart(rules: [rule])
        await supervisor.stopAll()
    }
}
```

（`FakeLLMProvider` 已存在于测试目录——先 grep 复用。）

- [ ] **Step 2: 实现装配**

`SageCore.makeDefault` 改为：

```swift
    public static func makeDefault(supportDirectory: URL, gateway: LLMGateway) -> Assembled {
        let extraction = ExtractionProvider(gateway: gateway)
        let dtRunner = NSAppleScriptRunner()
        let facts = DTFactsAdapter(local: extraction, runner: dtRunner)   // DT 位置可求值
        let engine = RuleEngine(provider: facts)
        let metadataProvider = ExtractionMetadataProvider(extraction: extraction, gateway: gateway)
        let dtActions = DTActions(runner: dtRunner)
        let executor = LocalActionExecutor(metadataProvider: metadataProvider, dtExecutor: dtActions)
        let journal = Journal(directory: supportDirectory, dtReverter: dtActions)
        let queue = ConfirmQueue(directory: supportDirectory)
        let store = RuleStore(directory: supportDirectory)
        let rulesProvider = RuleStoreRulesProvider(store: store)
        let coordinator = Coordinator(engine: engine, rulesProvider: rulesProvider,
                                      executor: executor, journal: journal, confirmQueue: queue)
        return Assembled(coordinator: coordinator, rulesProvider: rulesProvider,
                         manualIntake: ManualIntake())
    }
```

`WatcherSupervisor`：加 DT 支线（保持既有本地逻辑不动）：

```swift
    private let dtRunner: any AppleScriptRunning
    private let dtIsRunning: @Sendable () -> Bool
    private let onDTAvailabilityChange: (@Sendable (Bool) async -> Void)?
    private var dtWatcher: DTWatcher?

    public init(coordinator: Coordinator,
                dtRunner: any AppleScriptRunning = NSAppleScriptRunner(),
                dtIsRunning: @escaping @Sendable () -> Bool = DTAvailability.isRunning,
                onDTAvailabilityChange: (@Sendable (Bool) async -> Void)? = nil) { … }

    // start(rules:) 末尾追加：
    let dtGroups = DTWatcher.watchedGroups(rules: rules)
    if !dtGroups.isEmpty {
        let coordinator = self.coordinator
        let watcher = DTWatcher(groups: dtGroups, runner: dtRunner,
                                isRunning: dtIsRunning,
                                onEvent: { event in _ = await coordinator.handle(event) },
                                onAvailabilityChange: onDTAvailabilityChange)
        await watcher.start()
        dtWatcher = watcher
    }

    // stopAll() 追加：
    await dtWatcher?.stop()
    dtWatcher = nil
```

`AppModel`：加状态与接线（supervisor 构造处传回调）：

```swift
    /// DT 是否可用（仅在有 DT 监控组时有意义；未运行→菜单栏提示，spec §5）。
    public private(set) var dtAvailable: Bool = true
```

构造 `WatcherSupervisor` 改为（`init` 内 self 逃逸问题：先建 supervisor 再补回调不可行——用 weak 捕获的包装或把回调设为 `@MainActor` 闭包引用 `AppModel` 的 `nonisolated(unsafe)` 不佳。**推荐**：回调经 `Task { @MainActor in … }` 投递，supervisor 构造放到 `init` 末尾，闭包捕获 `self` 为 `weak`）：

```swift
        // init 中：先声明 var supervisorRef 不行（let 属性）——改用惰性静态工厂：
        self.supervisor = WatcherSupervisor(coordinator: coordinator)  // 保持既有
```

**实际做法**（避免 init 循环引用的最小方案）：`AppModel` 增加

```swift
    public func markDTAvailability(_ available: Bool) { dtAvailable = available }
```

并把 supervisor 的构造改为接受回调的形式放在 `bootstrap`/`init` 内可行版本：`WatcherSupervisor` 的 `onDTAvailabilityChange` 参数不在 init 传，改为 `public func setDTAvailabilityHandler(_ handler: @Sendable @escaping (Bool) async -> Void)`，`AppModel.init` 之后（`bootstrap` 里、或 `startInitialMonitoringIfEnabled` 前）调用：

```swift
        await model.supervisor.setDTAvailabilityHandler { [weak model] available in
            await MainActor.run { model?.markDTAvailability(available) }
        }
```

（`supervisor` 现为 private —— 提供 `internal` 访问或在 AppModel 内加一个 `func wireDTAvailability()` 方法内部完成。以编译通过 + 单一职责为准。）

`MenuBarView` 在 Toggle 之后加：

```swift
            if !app.dtAvailable {
                Label("DEVONthink 未运行，相关规则已暂停", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
```

- [ ] **Step 3: 构建 + 全量回归**

Run: `swift build` → Build complete
Run: `swift test --filter SageTests` → 全绿（含新 supervisor 冒烟测试）

- [ ] **Step 4: Commit**

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): DT 全链装配——SageCore/WatcherSupervisor/AppModel/菜单栏提示"
```

---

### Task 8: 规则编辑器 DT 参数 UI + 手动验证清单（构建 + 手动验证）

**Files:**
- Modify: `Sources/Sage/Views/RuleEditorView.swift`（DT 作用域行 + 4 个 DT 动作入菜单 + 参数编辑）
- Modify: `Sources/Sage/Views/RuleListView.swift`（scopeSummary 已覆盖 DT——确认无需改动）

**门槛：** 无自动化测试（纯 SwiftUI 参数控件）；`swift build` 通过 + 手动验证清单（spec §9：DT 交互手动验证）。

**Interfaces:**
- Consumes: `RuleScope.devonthink(database:groupPath:)`、`Action.dtImport/dtRename/dtAddTags/dtMoveToGroup`、`RuleEditorModel.addAction/draft`（既有）。

- [ ] **Step 1: 作用域编辑**

`RuleEditorView` Form 中（触发 Picker 之前）加作用域段（现文件若已有作用域 UI，按现状扩展 DT 项；无则新增段）：

```swift
                Section("作用域") {
                    ForEach(Array(model.draft.scopes.enumerated()), id: \.offset) { idx, scope in
                        HStack {
                            Text(Self.scopeLabel(scope)).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) { model.draft.scopes.remove(at: idx) } label: {
                                Image(systemName: "minus.circle")
                            }
                        }
                    }
                    Menu("添加作用域") {
                        Button("本地文件夹…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                model.draft.scopes.append(.localFolder(path: url.path, recursive: true))
                            }
                        }
                        Button("DEVONthink 组") {
                            model.draft.scopes.append(.devonthink(database: "数据库名", groupPath: "/收件箱"))
                        }
                        Button("仅手动") { model.draft.scopes.append(.manualOnly) }
                    }
                }
```

DT 作用域参数就地编辑：DT 作用域行替换为两个 TextField 绑定（用自定义 Binding 改写 `model.draft.scopes[idx]`）：

```swift
                        if case .devonthink(let db, let group) = scope {
                            TextField("数据库", text: Binding(
                                get: { db },
                                set: { model.draft.scopes[idx] = .devonthink(database: $0, groupPath: group) }))
                            TextField("组路径（/开头）", text: Binding(
                                get: { group },
                                set: { model.draft.scopes[idx] = .devonthink(database: db, groupPath: $0) }))
                        } else {
                            Text(Self.scopeLabel(scope)).lineLimit(1)
                        }
```

`scopeLabel` 静态助手：

```swift
    static func scopeLabel(_ scope: RuleScope) -> String {
        switch scope {
        case .localFolder(let path, let recursive):
            return "\((path as NSString).lastPathComponent)\(recursive ? "（含子目录）" : "")"
        case .devonthink(let db, let group): return "DT：\(db)\(group)"
        case .manualOnly: return "仅手动"
        }
    }
```

- [ ] **Step 2: DT 动作入添加菜单**

`Menu("添加动作")` 追加：

```swift
                    Divider()
                    Button("导入 DEVONthink…") {
                        model.addAction(.dtImport(database: "数据库名", groupPath: "/收件箱", tags: [], noteTemplate: nil))
                    }
                    Button("DEVONthink 内重命名") { model.addAction(.dtRename(template: "{title}")) }
                    Button("DEVONthink 加标签") { model.addAction(.dtAddTags(["标签"])) }
                    Button("DEVONthink 移动到组") { model.addAction(.dtMoveToGroup(database: "数据库名", groupPath: "/已归档")) }
```

动作行参数编辑：现文件的动作行显示逻辑处（`RuleEditorModel.describe` 文本行），为 DT 动作追加就地参数控件（模式与作用域一致：自定义 Binding 重写 `model.draft.actions[idx]`）。至少覆盖：dtImport 的 database/groupPath/tags(逗号分隔 TextField)/noteTemplate、dtRename 的 template、dtAddTags 的标签列表、dtMoveToGroup 的 database/groupPath。代码模式（以 dtImport 为例，其余同型）：

```swift
                        if case .dtImport(let db, let group, let tags, let note) = action {
                            VStack(alignment: .leading) {
                                Text("导入 DEVONthink").font(.caption).foregroundStyle(.secondary)
                                TextField("数据库", text: Binding(
                                    get: { db },
                                    set: { model.draft.actions[idx] = .dtImport(database: $0, groupPath: group, tags: tags, noteTemplate: note) }))
                                TextField("组路径", text: Binding(
                                    get: { group },
                                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: $0, tags: tags, noteTemplate: note) }))
                                TextField("标签（逗号分隔）", text: Binding(
                                    get: { tags.joined(separator: ",") },
                                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: group,
                                        tags: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                        noteTemplate: note) }))
                                TextField("备注模板（可用 {summary}）", text: Binding(
                                    get: { note ?? "" },
                                    set: { model.draft.actions[idx] = .dtImport(database: db, groupPath: group, tags: tags,
                                        noteTemplate: $0.isEmpty ? nil : $0) }))
                            }
                        }
```

- [ ] **Step 3: 构建 + 回归**

Run: `swift build` → Build complete
Run: `swift test --filter SageTests` → 全绿

- [ ] **Step 4: 手动验证清单（附在任务报告）**

真实 DEVONthink 环境（手动执行，报告列出即可）：
1. 建规则「作用域=本地文件夹；动作=导入 DEVONthink 到指定库/组 + 标签 + 备注 {summary}」→ 拖入文件 → DT 出现记录、标签备注正确；日志出现记录。
2. 日志中回滚该导入 → DT 记录进 DT 废纸篓。
3. 建规则「作用域=DT 组；动作=DT 加标签」→ 在 DT 该组新建/修改条目 → ≤60s 自动加标签。
4. 退出 DT → 菜单栏出现「DEVONthink 未运行」提示、无弹窗；重启 DT → 提示消失、监控恢复。
5. 文件名/标签含 `"`、`\`、换行等恶意字符 → 动作正常执行、无脚本错误（转义有效）。
6. DT 位置条目上的本地动作（如重命名模板）被拒绝并记录中文错误。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Views
git commit -m "feat(sage): 规则编辑器 DT 作用域与动作参数 UI"
```

---

## 自检记录（写计划者已核对）

- **spec §5 覆盖**：AppleScript 转义（Task 1/2）；导入返回 UUID 入 Journal 供回滚（Task 3/4）；DTWatcher 轮询 uuid+修改时间（Task 6）；DT FileFacts＝记录属性+纯文本（Task 5）；DT 未运行暂停+菜单栏提示+自动续（Task 6/7）。§4 DT 动作 4 种（Task 4/8）。§7.6 DT 导入可回滚（Task 3/4）。§8 DT 未运行不弹错误（Task 6）。§9 DT 手动清单（Task 8）。
- **类型一致性**：`DTReverting`（Task 3 定义、Task 4 实现、Task 7 注入 Journal）；`DTWatchedGroup`/`DTWatcher.watchedGroups`（Task 6 定义、Task 7 消费）；`ReversibleOp` 新 case 名在 Task 3/4/7 一致；`AppleScriptRunning.run(_:) -> String` 全计划一致。
- **已知需实现时核对的点（已在任务内标注）**：`CheapFacts`/`ExtractedFacts` memberwise init（Task 5 Step 1 先读）；`ExtractionProvider.belongsTo/matchesDescription` 抽取按现代码搬移（Task 5）；FolderWatcher 首轮基线语义对齐（Task 6）；AppModel/supervisor 回调接线的 init 循环引用规避（Task 7 给出两方案，以编译为准）；测试 helper（FakeLLMProvider/MetadataProviding stub）先 grep 复用。
- **有意不做（YAGNI）**：DT 数据库/组的图形化选择器（下拉候选需查询 DT，留后续迭代，文本框先行）；DT 自定义元数据写入（spec 提及「可同时写自定义元数据」——dtImport 暂不带 custom metadata 参数，现 Action 模型无此字段，扩展属破坏性 schema 变更，留待需求明确）；DTWatcher 对子组递归（spec 既定精确匹配，见 Plan 2 ledger 备忘）。
