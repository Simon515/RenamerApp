# Sage 核心引擎实施计划（第 1/5 份）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭建 Sage 的 SPM 骨架与纯逻辑核心：Domain 模型、条件求值（成本梯度）、规则匹配引擎、动作参数解析、规则持久化。

**Architecture:** 完全重写（spec：`docs/superpowers/specs/2026-07-18-sage-redesign-design.md`）。本份计划只做 Domain + Engine + Store——零 I/O 副作用（Store 除外），条件求值依赖 `FactsProvider` 协议按需取数，测试全部用伪造 Provider，不碰真实文件系统。旧 Renamer 目标保持原样不动，新代码在新增的 `Sage` 目标里。

**Tech Stack:** Swift 6（StrictConcurrency）、SPM、XCTest、macOS 14+。

## Global Constraints

- Swift tools version 6.0；目标平台 `.macOS(.v14)`；开启 `StrictConcurrency`。
- Domain 类型一律 `Codable + Sendable + Equatable`，禁止任何 I/O 依赖。
- 自定义错误遵循 `LocalizedError` 并实现 `errorDescription`（中文消息）。
- 注释中文、标识符英文。
- 规则 JSON 带 `version` 字段（当前 `1`）。
- 已知环境限制：仅 CommandLineTools 的机器 `swift test` 不可用，需完整 Xcode；每个测试步骤先 `swift build` 保证可编译，`swift test` 失败信息为 `no such module 'XCTest'` 时属环境问题，改在 Xcode 中 ⌘U 验证。

---

### Task 1: SPM 目标骨架

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Sage/App/main.swift`
- Create: `Tests/SageTests/SmokeTests.swift`

**Interfaces:**
- Produces: 可编译的 `Sage` 可执行目标与 `SageTests` 测试目标；后续所有任务的文件都放在 `Sources/Sage/` 与 `Tests/SageTests/` 下。

- [ ] **Step 1: 在 Package.swift 中新增目标**

在现有 `targets` 数组中追加（保留 Renamer 原有目标不动，`swiftSettings` 写法参考同文件中 Renamer 目标已有的 StrictConcurrency 配置）：

```swift
.executableTarget(
    name: "Sage",
    path: "Sources/Sage",
    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
),
.testTarget(
    name: "SageTests",
    dependencies: ["Sage"],
    path: "Tests/SageTests"
),
```

- [ ] **Step 2: 创建入口占位**

`Sources/Sage/App/main.swift`：

```swift
// Sage 入口占位；UI 与菜单栏形态在第 4 份计划中实现。
print("Sage core — engine only build")
```

- [ ] **Step 3: 创建冒烟测试**

`Tests/SageTests/SmokeTests.swift`：

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: 构建与测试**

Run: `swift build && swift test --filter SageTests`
Expected: 构建成功，1 个测试通过。

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/Sage Tests/SageTests
git commit -m "feat(sage): SPM 骨架，新增 Sage 目标与测试目标"
```

---

### Task 2: Domain 基础类型（RuleScope、StringMatch、枚举）

**Files:**
- Create: `Sources/Sage/Domain/RuleScope.swift`
- Create: `Sources/Sage/Domain/StringMatch.swift`
- Test: `Tests/SageTests/Domain/StringMatchTests.swift`

**Interfaces:**
- Produces:
  - `enum RuleScope: Codable, Sendable, Equatable` — `.localFolder(path: String, recursive: Bool)`、`.devonthink(database: String, groupPath: String)`、`.manualOnly`
  - `enum TriggerMode: String` — `.automatic`、`.manualOnly`
  - `enum ConditionLogic: String` — `.all`、`.any`
  - `enum ExecutionMode: String` — `.automatic`、`.confirmFirst`
  - `enum StringMatch` 及 `func matches(_ value: String) -> Bool`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Domain/StringMatchTests.swift`：

```swift
import XCTest
@testable import Sage

final class StringMatchTests: XCTestCase {
    func testEquals_忽略大小写() {
        XCTAssertTrue(StringMatch.equals("Invoice.PDF").matches("invoice.pdf"))
    }

    func testContains() {
        XCTAssertTrue(StringMatch.contains("发票").matches("2026年3月发票扫描件"))
        XCTAssertFalse(StringMatch.contains("发票").matches("收据"))
    }

    func testRegex() {
        XCTAssertTrue(StringMatch.regex(#"^\d{4}-\d{2}"#).matches("2026-03 report"))
        XCTAssertFalse(StringMatch.regex(#"^\d{4}-\d{2}"#).matches("report 2026"))
    }

    func testRegex_非法模式返回不匹配() {
        XCTAssertFalse(StringMatch.regex("([").matches("anything"))
    }

    func testCodable_往返() throws {
        let original = StringMatch.regex(#"\d+"#)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StringMatch.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'StringMatch'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/StringMatch.swift`：

```swift
import Foundation

/// 字符串匹配方式：规则条件中所有文本类比较的统一表达。
public enum StringMatch: Codable, Sendable, Equatable {
    case equals(String)      // 忽略大小写的相等
    case contains(String)    // 忽略大小写的包含
    case regex(String)       // 正则（区分大小写，由用户模式自行控制）

    public func matches(_ value: String) -> Bool {
        switch self {
        case .equals(let target):
            return value.caseInsensitiveCompare(target) == .orderedSame
        case .contains(let target):
            return value.range(of: target, options: .caseInsensitive) != nil
        case .regex(let pattern):
            // 非法正则视为不匹配，不抛错——规则求值不应因用户输入中断
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, range: range) != nil
        }
    }
}
```

`Sources/Sage/Domain/RuleScope.swift`：

```swift
/// 规则适用范围。
public enum RuleScope: Codable, Sendable, Equatable {
    case localFolder(path: String, recursive: Bool)
    case devonthink(database: String, groupPath: String)
    case manualOnly
}

/// 触发方式。
public enum TriggerMode: String, Codable, Sendable {
    case automatic   // 监控自动
    case manualOnly  // 仅手动
}

/// 条件组合逻辑（单层，spec 明确不做嵌套组）。
public enum ConditionLogic: String, Codable, Sendable {
    case all
    case any
}

/// 执行模式。
public enum ExecutionMode: String, Codable, Sendable {
    case automatic     // 自动执行
    case confirmFirst  // 先入确认队列
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter StringMatchTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Domain Tests/SageTests/Domain
git commit -m "feat(sage): Domain 基础类型 RuleScope/StringMatch 与规则枚举"
```

---

### Task 3: Condition 与成本梯度

**Files:**
- Create: `Sources/Sage/Domain/Condition.swift`
- Test: `Tests/SageTests/Domain/ConditionTests.swift`

**Interfaces:**
- Produces:
  - `enum CostTier: Int, Comparable` — `.free = 0`、`.extraction = 1`、`.llm = 2`
  - `enum Condition: Codable, Sendable, Equatable`，含属性 `var tier: CostTier`
  - 条件全集（对应 spec §4 表格）：
    - `.name(StringMatch)`、`.fileExtension(StringMatch)`、`.sizeBytes(min: Int64?, max: Int64?)`、`.createdWithinDays(Int)`、`.modifiedWithinDays(Int)`、`.utTypeConforms(String)`
    - `.textContent(StringMatch)`、`.isDuplicate`、`.captureDateWithinDays(Int)`、`.sourceURL(StringMatch)`
    - `.contentBelongsTo(category: String, minConfidence: Double)`、`.contentMatchesDescription(String)`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Domain/ConditionTests.swift`：

```swift
import XCTest
@testable import Sage

final class ConditionTests: XCTestCase {
    func testTier_零成本条件() {
        XCTAssertEqual(Condition.name(.contains("发票")).tier, .free)
        XCTAssertEqual(Condition.fileExtension(.equals("pdf")).tier, .free)
        XCTAssertEqual(Condition.sizeBytes(min: 1, max: nil).tier, .free)
        XCTAssertEqual(Condition.createdWithinDays(7).tier, .free)
        XCTAssertEqual(Condition.modifiedWithinDays(7).tier, .free)
        XCTAssertEqual(Condition.utTypeConforms("com.adobe.pdf").tier, .free)
    }

    func testTier_提取条件() {
        XCTAssertEqual(Condition.textContent(.contains("税号")).tier, .extraction)
        XCTAssertEqual(Condition.isDuplicate.tier, .extraction)
        XCTAssertEqual(Condition.captureDateWithinDays(30).tier, .extraction)
        XCTAssertEqual(Condition.sourceURL(.contains("apple.com")).tier, .extraction)
    }

    func testTier_LLM条件() {
        XCTAssertEqual(Condition.contentBelongsTo(category: "发票", minConfidence: 0.7).tier, .llm)
        XCTAssertEqual(Condition.contentMatchesDescription("这是一张发票").tier, .llm)
    }

    func testTier_可比较() {
        XCTAssertLessThan(CostTier.free, CostTier.extraction)
        XCTAssertLessThan(CostTier.extraction, CostTier.llm)
    }

    func testCodable_往返() throws {
        let original = Condition.contentBelongsTo(category: "合同", minConfidence: 0.8)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Condition.self, from: data), original)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'Condition'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/Condition.swift`：

```swift
import Foundation

/// 条件求值成本档次：引擎按档次从低到高求值，档次内条件全部通过才进入下一档。
public enum CostTier: Int, Codable, Sendable, Comparable {
    case free = 0        // 文件属性，零成本
    case extraction = 1  // 需要内容提取（文本/哈希/EXIF）
    case llm = 2         // 需要 LLM 调用

    public static func < (lhs: CostTier, rhs: CostTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 规则条件全集（spec §4）。
public enum Condition: Codable, Sendable, Equatable {
    // 零成本
    case name(StringMatch)
    case fileExtension(StringMatch)
    case sizeBytes(min: Int64?, max: Int64?)
    case createdWithinDays(Int)
    case modifiedWithinDays(Int)
    case utTypeConforms(String)
    // 内容提取
    case textContent(StringMatch)
    case isDuplicate
    case captureDateWithinDays(Int)
    case sourceURL(StringMatch)
    // LLM
    case contentBelongsTo(category: String, minConfidence: Double)
    case contentMatchesDescription(String)

    public var tier: CostTier {
        switch self {
        case .name, .fileExtension, .sizeBytes, .createdWithinDays,
             .modifiedWithinDays, .utTypeConforms:
            return .free
        case .textContent, .isDuplicate, .captureDateWithinDays, .sourceURL:
            return .extraction
        case .contentBelongsTo, .contentMatchesDescription:
            return .llm
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ConditionTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Domain/Condition.swift Tests/SageTests/Domain/ConditionTests.swift
git commit -m "feat(sage): Condition 全集与 CostTier 成本梯度"
```

---

### Task 4: Action 与 Rule

**Files:**
- Create: `Sources/Sage/Domain/Action.swift`
- Create: `Sources/Sage/Domain/Rule.swift`
- Test: `Tests/SageTests/Domain/RuleTests.swift`

**Interfaces:**
- Produces:
  - `enum Action: Codable, Sendable, Equatable`（对应 spec §4 动作表）：
    - 本地：`.moveTo(path: String)`、`.copyTo(path: String)`、`.rename(template: String)`、`.addFinderTags([String])`、`.moveToTrash`
    - DT：`.dtImport(database: String, groupPath: String, tags: [String], noteTemplate: String?)`、`.dtRename(template: String)`、`.dtAddTags([String])`、`.dtMoveToGroup(database: String, groupPath: String)`
    - LLM：`.llmExtractMetadata`、`.llmRename(instruction: String)`
    - 控制：`.continueMatching`（默认首个匹配即停；含此动作则放行后续规则）
  - `struct Rule: Codable, Sendable, Equatable, Identifiable` — 字段 `id: UUID`、`name: String`、`enabled: Bool`、`scopes: [RuleScope]`、`trigger: TriggerMode`、`conditionLogic: ConditionLogic`、`conditions: [Condition]`、`actions: [Action]`、`executionMode: ExecutionMode`
  - `Rule` 计算属性：`var usesLLM: Bool`（条件或动作含 LLM 档）、`var requiresConfirmation: Bool`（`executionMode == .confirmFirst` 或动作含 `.moveToTrash`——spec §7.1 删除强制入队）

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Domain/RuleTests.swift`：

```swift
import XCTest
@testable import Sage

final class RuleTests: XCTestCase {
    private func makeRule(conditions: [Condition] = [.fileExtension(.equals("pdf"))],
                          actions: [Action] = [.moveTo(path: "/tmp/out")],
                          executionMode: ExecutionMode = .automatic) -> Rule {
        Rule(id: UUID(), name: "测试规则", enabled: true,
             scopes: [.localFolder(path: "/tmp/in", recursive: false)],
             trigger: .automatic, conditionLogic: .all,
             conditions: conditions, actions: actions, executionMode: executionMode)
    }

    func testUsesLLM_条件含LLM档() {
        let rule = makeRule(conditions: [.contentBelongsTo(category: "发票", minConfidence: 0.7)])
        XCTAssertTrue(rule.usesLLM)
    }

    func testUsesLLM_动作含LLM() {
        XCTAssertTrue(makeRule(actions: [.llmRename(instruction: "按标题命名")]).usesLLM)
        XCTAssertFalse(makeRule().usesLLM)
    }

    func testRequiresConfirmation_废纸篓动作强制() {
        let rule = makeRule(actions: [.moveToTrash], executionMode: .automatic)
        XCTAssertTrue(rule.requiresConfirmation)
    }

    func testRequiresConfirmation_跟随执行模式() {
        XCTAssertTrue(makeRule(executionMode: .confirmFirst).requiresConfirmation)
        XCTAssertFalse(makeRule(executionMode: .automatic).requiresConfirmation)
    }

    func testCodable_往返() throws {
        let rule = makeRule()
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(Rule.self, from: data), rule)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'Rule'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/Action.swift`：

```swift
/// 规则动作全集（spec §4）。执行语义在第 3/5 份计划（Execution 层）实现。
public enum Action: Codable, Sendable, Equatable {
    // 本地文件
    case moveTo(path: String)
    case copyTo(path: String)
    case rename(template: String)
    case addFinderTags([String])
    case moveToTrash
    // DEVONthink
    case dtImport(database: String, groupPath: String, tags: [String], noteTemplate: String?)
    case dtRename(template: String)
    case dtAddTags([String])
    case dtMoveToGroup(database: String, groupPath: String)
    // LLM
    case llmExtractMetadata
    case llmRename(instruction: String)
    // 控制
    case continueMatching

    /// 该动作是否需要 LLM 参与。
    public var usesLLM: Bool {
        switch self {
        case .llmExtractMetadata, .llmRename: return true
        default: return false
        }
    }
}
```

`Sources/Sage/Domain/Rule.swift`：

```swift
import Foundation

/// 规则：Sage 的核心配置单元（spec §4）。
public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var scopes: [RuleScope]
    public var trigger: TriggerMode
    public var conditionLogic: ConditionLogic
    public var conditions: [Condition]
    public var actions: [Action]
    public var executionMode: ExecutionMode

    public init(id: UUID, name: String, enabled: Bool, scopes: [RuleScope],
                trigger: TriggerMode, conditionLogic: ConditionLogic,
                conditions: [Condition], actions: [Action], executionMode: ExecutionMode) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.scopes = scopes
        self.trigger = trigger
        self.conditionLogic = conditionLogic
        self.conditions = conditions
        self.actions = actions
        self.executionMode = executionMode
    }

    /// 条件或动作是否用到 LLM（UI 中显示 ✦ 标记的依据）。
    public var usesLLM: Bool {
        conditions.contains { $0.tier == .llm } || actions.contains { $0.usesLLM }
    }

    /// 是否必须走确认队列：显式设置，或含删除类动作（spec §7.1 强制）。
    public var requiresConfirmation: Bool {
        executionMode == .confirmFirst || actions.contains(.moveToTrash)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter RuleTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Domain Tests/SageTests/Domain
git commit -m "feat(sage): Action 全集与 Rule 模型"
```

---

### Task 5: FileEvent、FileFacts 与 FactsProvider

**Files:**
- Create: `Sources/Sage/Domain/FileEvent.swift`
- Create: `Sources/Sage/Domain/FileFacts.swift`
- Test: `Tests/SageTests/Domain/FileEventTests.swift`

**Interfaces:**
- Produces:
  - `enum EventSource: Codable, Sendable, Equatable` — `.folderWatch(root: String)`、`.dtWatch(database: String, groupPath: String)`、`.manual`
  - `struct FileEvent: Sendable, Equatable` — `location: FileLocation`、`source: EventSource`
  - `enum FileLocation: Codable, Sendable, Equatable, Hashable` — `.local(path: String)`、`.devonthink(uuid: String, database: String, groupPath: String)`
  - `struct CheapFacts: Sendable, Equatable` — `name: String`（不含扩展名）、`fileExtension: String`（小写、不含点）、`sizeBytes: Int64`、`createdAt: Date?`、`modifiedAt: Date?`、`utType: String?`
  - `struct ExtractedFacts: Sendable, Equatable` — `text: String?`、`contentHash: String?`、`isDuplicate: Bool`、`captureDate: Date?`、`sourceURL: String?`
  - `struct SemanticVerdict: Sendable, Equatable` — `matches: Bool`、`confidence: Double`
  - `protocol FactsProvider: Sendable`：
    ```swift
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict
    ```
    （真实实现在第 2/5 份计划；本计划内测试用 `FakeFactsProvider`。）
  - `FileEvent` 方法 `func isCovered(by scope: RuleScope) -> Bool`：作用域判定。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Domain/FileEventTests.swift`：

```swift
import XCTest
@testable import Sage

final class FileEventTests: XCTestCase {
    func testScope_本地非递归_仅直接子文件() {
        let scope = RuleScope.localFolder(path: "/in", recursive: false)
        let direct = FileEvent(location: .local(path: "/in/a.pdf"), source: .manual)
        let nested = FileEvent(location: .local(path: "/in/sub/a.pdf"), source: .manual)
        XCTAssertTrue(direct.isCovered(by: scope))
        XCTAssertFalse(nested.isCovered(by: scope))
    }

    func testScope_本地递归_含子目录() {
        let scope = RuleScope.localFolder(path: "/in", recursive: true)
        let nested = FileEvent(location: .local(path: "/in/sub/deep/a.pdf"), source: .manual)
        XCTAssertTrue(nested.isCovered(by: scope))
    }

    func testScope_路径前缀不越界() {
        // "/inbox" 不应被 "/in" 覆盖
        let scope = RuleScope.localFolder(path: "/in", recursive: true)
        let outside = FileEvent(location: .local(path: "/inbox/a.pdf"), source: .manual)
        XCTAssertFalse(outside.isCovered(by: scope))
    }

    func testScope_DT位置匹配库与组() {
        let scope = RuleScope.devonthink(database: "财务", groupPath: "/收件箱")
        let hit = FileEvent(location: .devonthink(uuid: "X", database: "财务", groupPath: "/收件箱"),
                            source: .dtWatch(database: "财务", groupPath: "/收件箱"))
        let miss = FileEvent(location: .devonthink(uuid: "Y", database: "个人", groupPath: "/收件箱"),
                             source: .dtWatch(database: "个人", groupPath: "/收件箱"))
        XCTAssertTrue(hit.isCovered(by: scope))
        XCTAssertFalse(miss.isCovered(by: scope))
    }

    func testScope_manualOnly_只覆盖手动来源() {
        let scope = RuleScope.manualOnly
        XCTAssertTrue(FileEvent(location: .local(path: "/x/a.pdf"), source: .manual).isCovered(by: scope))
        XCTAssertFalse(FileEvent(location: .local(path: "/x/a.pdf"),
                                 source: .folderWatch(root: "/x")).isCovered(by: scope))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'FileEvent'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/FileEvent.swift`：

```swift
import Foundation

/// 事件来源：三个 Watcher 产出统一事件（spec §3）。
public enum EventSource: Codable, Sendable, Equatable {
    case folderWatch(root: String)
    case dtWatch(database: String, groupPath: String)
    case manual
}

/// 文件位置：本地路径或 DT 记录。
public enum FileLocation: Codable, Sendable, Equatable, Hashable {
    case local(path: String)
    case devonthink(uuid: String, database: String, groupPath: String)
}

/// 统一文件事件。
public struct FileEvent: Sendable, Equatable {
    public var location: FileLocation
    public var source: EventSource

    public init(location: FileLocation, source: EventSource) {
        self.location = location
        self.source = source
    }

    /// 该事件是否落在给定作用域内。
    public func isCovered(by scope: RuleScope) -> Bool {
        switch (scope, location) {
        case (.manualOnly, _):
            return source == .manual
        case (.localFolder(let root, let recursive), .local(let path)):
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            let rootParts = rootURL.pathComponents
            let fileParts = fileURL.pathComponents
            // 目录组件前缀比较，避免 "/in" 误覆盖 "/inbox"
            guard fileParts.count > rootParts.count,
                  Array(fileParts.prefix(rootParts.count)) == rootParts else { return false }
            if recursive { return true }
            return fileParts.count == rootParts.count + 1
        case (.devonthink(let db, let group), .devonthink(_, let eventDB, let eventGroup)):
            return db == eventDB && group == eventGroup
        default:
            return false
        }
    }
}
```

`Sources/Sage/Domain/FileFacts.swift`：

```swift
import Foundation

/// 零成本文件属性。
public struct CheapFacts: Sendable, Equatable {
    public var name: String          // 不含扩展名
    public var fileExtension: String // 小写、不含点
    public var sizeBytes: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var utType: String?

    public init(name: String, fileExtension: String, sizeBytes: Int64,
                createdAt: Date? = nil, modifiedAt: Date? = nil, utType: String? = nil) {
        self.name = name
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.utType = utType
    }
}

/// 内容提取结果。
public struct ExtractedFacts: Sendable, Equatable {
    public var text: String?
    public var contentHash: String?
    public var isDuplicate: Bool
    public var captureDate: Date?
    public var sourceURL: String?

    public init(text: String? = nil, contentHash: String? = nil, isDuplicate: Bool = false,
                captureDate: Date? = nil, sourceURL: String? = nil) {
        self.text = text
        self.contentHash = contentHash
        self.isDuplicate = isDuplicate
        self.captureDate = captureDate
        self.sourceURL = sourceURL
    }
}

/// LLM 语义判断结果。
public struct SemanticVerdict: Sendable, Equatable {
    public var matches: Bool
    public var confidence: Double

    public init(matches: Bool, confidence: Double) {
        self.matches = matches
        self.confidence = confidence
    }
}

/// 按需取数协议：引擎只在条件档次需要时才调用对应方法（spec §3 成本梯度）。
/// 真实实现（Extraction + LLMGateway）在第 2/5 份计划。
public protocol FactsProvider: Sendable {
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter FileEventTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Domain Tests/SageTests/Domain
git commit -m "feat(sage): FileEvent/FileFacts/FactsProvider 与作用域判定"
```

---

### Task 6: ConditionEvaluator

**Files:**
- Create: `Sources/Sage/Engine/ConditionEvaluator.swift`
- Create: `Tests/SageTests/Support/FakeFactsProvider.swift`
- Test: `Tests/SageTests/Engine/ConditionEvaluatorTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `Condition`/`CostTier`，Task 5 的 `FactsProvider` 及各 Facts 类型。
- Produces:
  - `struct ConditionEvaluator: Sendable`，初始化 `init(provider: any FactsProvider, now: @Sendable () -> Date = { Date() })`
  - `func evaluate(_ condition: Condition, at location: FileLocation) async throws -> Bool`
  - 测试基建 `FakeFactsProvider`（后续任务复用）：可注入各类 Facts 并记录调用次数。

- [ ] **Step 1: 写测试基建**

`Tests/SageTests/Support/FakeFactsProvider.swift`：

```swift
import Foundation
@testable import Sage

/// 测试用伪造 Provider：注入固定结果，并计数各档调用次数。
final class FakeFactsProvider: FactsProvider, @unchecked Sendable {
    var cheap: CheapFacts
    var extracted: ExtractedFacts
    var verdicts: [String: SemanticVerdict] // key = 分类名或描述文本
    private(set) var cheapCalls = 0
    private(set) var extractionCalls = 0
    private(set) var llmCalls = 0

    init(cheap: CheapFacts = CheapFacts(name: "file", fileExtension: "pdf", sizeBytes: 100),
         extracted: ExtractedFacts = ExtractedFacts(),
         verdicts: [String: SemanticVerdict] = [:]) {
        self.cheap = cheap
        self.extracted = extracted
        self.verdicts = verdicts
    }

    func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        cheapCalls += 1
        return cheap
    }

    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        extractionCalls += 1
        return extracted
    }

    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
        llmCalls += 1
        return verdicts[category] ?? SemanticVerdict(matches: false, confidence: 0)
    }

    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
        llmCalls += 1
        return verdicts[description] ?? SemanticVerdict(matches: false, confidence: 0)
    }
}
```

- [ ] **Step 2: 写失败测试**

`Tests/SageTests/Engine/ConditionEvaluatorTests.swift`：

```swift
import XCTest
@testable import Sage

final class ConditionEvaluatorTests: XCTestCase {
    private let loc = FileLocation.local(path: "/in/a.pdf")

    func testName与扩展名() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "2026年3月发票", fileExtension: "pdf", sizeBytes: 100))
        let eval = ConditionEvaluator(provider: provider)
        let hit = try await eval.evaluate(.name(.contains("发票")), at: loc)
        let miss = try await eval.evaluate(.fileExtension(.equals("jpg")), at: loc)
        XCTAssertTrue(hit)
        XCTAssertFalse(miss)
    }

    func testSize区间() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 5000))
        let eval = ConditionEvaluator(provider: provider)
        let inRange = try await eval.evaluate(.sizeBytes(min: 1000, max: 10000), at: loc)
        let below = try await eval.evaluate(.sizeBytes(min: 6000, max: nil), at: loc)
        XCTAssertTrue(inRange)
        XCTAssertFalse(below)
    }

    func testCreatedWithinDays_用注入时钟() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: threeDaysAgo))
        let eval = ConditionEvaluator(provider: provider, now: { now })
        let within = try await eval.evaluate(.createdWithinDays(7), at: loc)
        let outside = try await eval.evaluate(.createdWithinDays(2), at: loc)
        XCTAssertTrue(within)
        XCTAssertFalse(outside)
    }

    func testCreatedWithinDays_无日期视为不匹配() async throws {
        let provider = FakeFactsProvider(
            cheap: CheapFacts(name: "f", fileExtension: "pdf", sizeBytes: 1, createdAt: nil))
        let eval = ConditionEvaluator(provider: provider)
        let result = try await eval.evaluate(.createdWithinDays(7), at: loc)
        XCTAssertFalse(result)
    }

    func testTextContent与重复() async throws {
        let provider = FakeFactsProvider(
            extracted: ExtractedFacts(text: "增值税发票 税号123", isDuplicate: true))
        let eval = ConditionEvaluator(provider: provider)
        let text = try await eval.evaluate(.textContent(.contains("税号")), at: loc)
        let dup = try await eval.evaluate(.isDuplicate, at: loc)
        XCTAssertTrue(text)
        XCTAssertTrue(dup)
    }

    func testContentBelongsTo_置信度阈值() async throws {
        let provider = FakeFactsProvider(
            verdicts: ["发票": SemanticVerdict(matches: true, confidence: 0.6)])
        let eval = ConditionEvaluator(provider: provider)
        let low = try await eval.evaluate(.contentBelongsTo(category: "发票", minConfidence: 0.7), at: loc)
        let ok = try await eval.evaluate(.contentBelongsTo(category: "发票", minConfidence: 0.5), at: loc)
        XCTAssertFalse(low)
        XCTAssertTrue(ok)
    }

    func testFree条件不触发提取与LLM() async throws {
        let provider = FakeFactsProvider()
        let eval = ConditionEvaluator(provider: provider)
        _ = try await eval.evaluate(.name(.contains("x")), at: loc)
        XCTAssertEqual(provider.extractionCalls, 0)
        XCTAssertEqual(provider.llmCalls, 0)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'ConditionEvaluator'`。

- [ ] **Step 4: 实现**

`Sources/Sage/Engine/ConditionEvaluator.swift`：

```swift
import Foundation

/// 单条件求值器：只向 Provider 索取该条件档次所需的数据。
public struct ConditionEvaluator: Sendable {
    private let provider: any FactsProvider
    private let now: @Sendable () -> Date

    public init(provider: any FactsProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    public func evaluate(_ condition: Condition, at location: FileLocation) async throws -> Bool {
        switch condition {
        case .name(let match):
            return match.matches(try await provider.cheapFacts(for: location).name)
        case .fileExtension(let match):
            return match.matches(try await provider.cheapFacts(for: location).fileExtension)
        case .sizeBytes(let min, let max):
            let size = try await provider.cheapFacts(for: location).sizeBytes
            if let min, size < min { return false }
            if let max, size > max { return false }
            return true
        case .createdWithinDays(let days):
            return withinDays(try await provider.cheapFacts(for: location).createdAt, days: days)
        case .modifiedWithinDays(let days):
            return withinDays(try await provider.cheapFacts(for: location).modifiedAt, days: days)
        case .utTypeConforms(let identifier):
            return try await provider.cheapFacts(for: location).utType == identifier
        case .textContent(let match):
            guard let text = try await provider.extractedFacts(for: location).text else { return false }
            return match.matches(text)
        case .isDuplicate:
            return try await provider.extractedFacts(for: location).isDuplicate
        case .captureDateWithinDays(let days):
            return withinDays(try await provider.extractedFacts(for: location).captureDate, days: days)
        case .sourceURL(let match):
            guard let url = try await provider.extractedFacts(for: location).sourceURL else { return false }
            return match.matches(url)
        case .contentBelongsTo(let category, let minConfidence):
            let verdict = try await provider.belongsTo(category: category, at: location)
            return verdict.matches && verdict.confidence >= minConfidence
        case .contentMatchesDescription(let description):
            let verdict = try await provider.matchesDescription(description, at: location)
            return verdict.matches
        }
    }

    /// 日期缺失视为不匹配（保守策略：宁可不触发规则）。
    private func withinDays(_ date: Date?, days: Int) -> Bool {
        guard let date else { return false }
        return now().timeIntervalSince(date) <= Double(days) * 86400
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift build && swift test --filter ConditionEvaluatorTests`
Expected: PASS（7 个测试）。

- [ ] **Step 6: Commit**

```bash
git add Sources/Sage/Engine Tests/SageTests
git commit -m "feat(sage): ConditionEvaluator 与 FakeFactsProvider 测试基建"
```

---

### Task 7: RuleEngine（作用域过滤、成本梯度、首中即停）

**Files:**
- Create: `Sources/Sage/Domain/ActionPlan.swift`
- Create: `Sources/Sage/Engine/RuleEngine.swift`
- Test: `Tests/SageTests/Engine/RuleEngineTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `Rule`，Task 5 的 `FileEvent`/`isCovered(by:)`，Task 6 的 `ConditionEvaluator` 与 `FakeFactsProvider`。
- Produces:
  - `struct PlannedActions: Sendable, Equatable` — `ruleID: UUID`、`ruleName: String`、`location: FileLocation`、`actions: [Action]`、`requiresConfirmation: Bool`
  - `struct ActionPlan: Sendable, Equatable` — `event: FileEvent`、`planned: [PlannedActions]`（多条规则命中且放行时可多项）
  - `struct RuleEngine: Sendable`，`init(provider: any FactsProvider)`
  - `func plan(for event: FileEvent, rules: [Rule]) async -> ActionPlan`
  - 匹配语义：按 `rules` 顺序；跳过 `enabled == false`、作用域不覆盖、以及自动来源事件上的 `trigger == .manualOnly` 规则；条件先按 `tier` 升序排序再按 `conditionLogic` 求值（`.all` 短路失败、`.any` 短路成功）；单条规则求值抛错（如 LLM 失败）时该规则视为不匹配并继续下一条（错误上抛留给调用方记日志，本层吞掉以不阻塞其他规则——spec §8）；命中后默认停止，动作含 `.continueMatching` 才继续匹配后续规则。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Engine/RuleEngineTests.swift`：

```swift
import XCTest
@testable import Sage

final class RuleEngineTests: XCTestCase {
    private let event = FileEvent(location: .local(path: "/in/发票2026.pdf"),
                                  source: .folderWatch(root: "/in"))

    private func makeRule(name: String = "R",
                          scopes: [RuleScope] = [.localFolder(path: "/in", recursive: false)],
                          trigger: TriggerMode = .automatic,
                          logic: ConditionLogic = .all,
                          conditions: [Condition],
                          actions: [Action] = [.moveTo(path: "/out")],
                          enabled: Bool = true) -> Rule {
        Rule(id: UUID(), name: name, enabled: enabled, scopes: scopes, trigger: trigger,
             conditionLogic: logic, conditions: conditions, actions: actions,
             executionMode: .automatic)
    }

    private func makeProvider() -> FakeFactsProvider {
        FakeFactsProvider(cheap: CheapFacts(name: "发票2026", fileExtension: "pdf", sizeBytes: 100))
    }

    func test命中生成计划() async {
        let engine = RuleEngine(provider: makeProvider())
        let rule = makeRule(conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(plan.planned.count, 1)
        XCTAssertEqual(plan.planned[0].ruleID, rule.id)
        XCTAssertEqual(plan.planned[0].actions, [.moveTo(path: "/out")])
    }

    func test首中即停() async {
        let engine = RuleEngine(provider: makeProvider())
        let first = makeRule(name: "第一", conditions: [.fileExtension(.equals("pdf"))])
        let second = makeRule(name: "第二", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [first, second])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["第一"])
    }

    func testContinueMatching放行后续规则() async {
        let engine = RuleEngine(provider: makeProvider())
        let first = makeRule(name: "第一", conditions: [.fileExtension(.equals("pdf"))],
                             actions: [.addFinderTags(["票据"]), .continueMatching])
        let second = makeRule(name: "第二", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [first, second])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["第一", "第二"])
    }

    func test跳过禁用与作用域外与仅手动() async {
        let engine = RuleEngine(provider: makeProvider())
        let disabled = makeRule(name: "禁用", conditions: [], enabled: false)
        let outOfScope = makeRule(name: "别处",
                                  scopes: [.localFolder(path: "/elsewhere", recursive: true)],
                                  conditions: [])
        let manualOnly = makeRule(name: "仅手动", trigger: .manualOnly, conditions: [])
        let plan = await engine.plan(for: event, rules: [disabled, outOfScope, manualOnly])
        XCTAssertTrue(plan.planned.isEmpty)
    }

    func testAll短路_零成本失败不触发LLM() async {
        let provider = makeProvider()
        let engine = RuleEngine(provider: provider)
        let rule = makeRule(logic: .all, conditions: [
            .contentBelongsTo(category: "发票", minConfidence: 0.7), // LLM 档，写在前面
            .fileExtension(.equals("jpg")),                          // 零成本，会失败
        ])
        _ = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(provider.llmCalls, 0, "零成本条件失败后不应调用 LLM")
    }

    func testAny短路_零成本命中不触发LLM() async {
        let provider = makeProvider()
        let engine = RuleEngine(provider: provider)
        let rule = makeRule(logic: .any, conditions: [
            .contentBelongsTo(category: "发票", minConfidence: 0.7),
            .fileExtension(.equals("pdf")), // 零成本，会命中
        ])
        let plan = await engine.plan(for: event, rules: [rule])
        XCTAssertEqual(plan.planned.count, 1)
        XCTAssertEqual(provider.llmCalls, 0)
    }

    func test求值抛错的规则视为不匹配且不阻塞后续() async {
        final class ThrowingProvider: FactsProvider, @unchecked Sendable {
            func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
                CheapFacts(name: "发票2026", fileExtension: "pdf", sizeBytes: 1)
            }
            func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
                struct Boom: Error {}
                throw Boom()
            }
            func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
                SemanticVerdict(matches: false, confidence: 0)
            }
            func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
                SemanticVerdict(matches: false, confidence: 0)
            }
        }
        let engine = RuleEngine(provider: ThrowingProvider())
        let broken = makeRule(name: "会抛错", conditions: [.textContent(.contains("税号"))])
        let healthy = makeRule(name: "健康", conditions: [.fileExtension(.equals("pdf"))])
        let plan = await engine.plan(for: event, rules: [broken, healthy])
        XCTAssertEqual(plan.planned.map(\.ruleName), ["健康"])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'RuleEngine'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/ActionPlan.swift`：

```swift
import Foundation

/// 单条规则命中后待执行的动作集。
public struct PlannedActions: Sendable, Equatable {
    public var ruleID: UUID
    public var ruleName: String
    public var location: FileLocation
    public var actions: [Action]
    public var requiresConfirmation: Bool

    public init(ruleID: UUID, ruleName: String, location: FileLocation,
                actions: [Action], requiresConfirmation: Bool) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.location = location
        self.actions = actions
        self.requiresConfirmation = requiresConfirmation
    }
}

/// 一次事件的完整执行计划。
public struct ActionPlan: Sendable, Equatable {
    public var event: FileEvent
    public var planned: [PlannedActions]

    public init(event: FileEvent, planned: [PlannedActions]) {
        self.event = event
        self.planned = planned
    }
}
```

`Sources/Sage/Engine/RuleEngine.swift`：

```swift
import Foundation

/// 规则匹配引擎：事件 → 按序匹配规则 → ActionPlan（spec §3、§4）。
public struct RuleEngine: Sendable {
    private let evaluator: ConditionEvaluator

    public init(provider: any FactsProvider) {
        self.evaluator = ConditionEvaluator(provider: provider)
    }

    public func plan(for event: FileEvent, rules: [Rule]) async -> ActionPlan {
        var planned: [PlannedActions] = []
        for rule in rules {
            guard rule.enabled else { continue }
            guard rule.scopes.contains(where: { event.isCovered(by: $0) }) else { continue }
            // 自动来源事件不触发「仅手动」规则；手动来源事件两种都可触发
            if event.source != .manual && rule.trigger == .manualOnly { continue }

            guard await matches(rule, event: event) else { continue }

            planned.append(PlannedActions(
                ruleID: rule.id, ruleName: rule.name, location: event.location,
                actions: rule.actions, requiresConfirmation: rule.requiresConfirmation))

            // 默认首中即停；含 continueMatching 才放行后续规则
            if !rule.actions.contains(.continueMatching) { break }
        }
        return ActionPlan(event: event, planned: planned)
    }

    /// 条件按成本档次升序求值：all 短路失败，any 短路成功。
    /// 求值抛错（LLM/提取失败）视为不匹配——不阻塞其他规则（spec §8），
    /// 错误的记录与重试由 Execution 层负责（第 3/5 份计划）。
    private func matches(_ rule: Rule, event: FileEvent) async -> Bool {
        if rule.conditions.isEmpty { return true }
        let ordered = rule.conditions.sorted { $0.tier < $1.tier }
        do {
            switch rule.conditionLogic {
            case .all:
                for condition in ordered {
                    if !(try await evaluator.evaluate(condition, at: event.location)) { return false }
                }
                return true
            case .any:
                for condition in ordered {
                    if try await evaluator.evaluate(condition, at: event.location) { return true }
                }
                return false
            }
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter RuleEngineTests`
Expected: PASS（7 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): RuleEngine 匹配管线（作用域/成本梯度/首中即停）"
```

---

### Task 8: TemplateResolver（命名模板令牌）

**Files:**
- Create: `Sources/Sage/Engine/TemplateResolver.swift`
- Test: `Tests/SageTests/Engine/TemplateResolverTests.swift`

**Interfaces:**
- Consumes: 无（纯字符串处理）。
- Produces:
  - `struct ExtractedMetadata: Codable, Sendable, Equatable` — `title: String?`、`date: Date?`、`category: String?`、`tags: [String]`、`summary: String?`、`source: String?`（LLM 动作 `.llmExtractMetadata` 的产物类型，第 2/5 份计划的 LLM 层填充它）
  - `struct TemplateResolver: Sendable`
  - `func resolve(_ template: String, metadata: ExtractedMetadata, fallbackName: String) -> String`
  - 令牌语义（沿用 spec §4）：`{title}`、`{date}`（默认 `yyyy-MM-dd`）、`{date:格式}`、`{category}`、`{source}`；令牌值缺失时 `{title}` 回退 `fallbackName`，其余令牌替换为空串；结果做文件名清洗（非法字符 `/:` 替换为 `-`，模板中显式写出的 `/` 保留为子目录分隔符——即先按模板中的 `/` 切段、逐段清洗再拼回）。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Engine/TemplateResolverTests.swift`：

```swift
import XCTest
@testable import Sage

final class TemplateResolverTests: XCTestCase {
    private let resolver = TemplateResolver()

    private var metadata: ExtractedMetadata {
        ExtractedMetadata(title: "三月增值税发票", date: Date(timeIntervalSince1970: 1_772_236_800),
                          category: "财务/发票", tags: ["发票"], summary: nil, source: "税务局")
    }

    func test基本令牌() {
        let result = resolver.resolve("{date}-{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026-02-28-三月增值税发票")
    }

    func test自定义日期格式() {
        let result = resolver.resolve("{date:yyyy}/{date:MM}/{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026/02/三月增值税发票")
    }

    func test日期格式内含斜杠_按数据清洗不产生子目录() {
        // 想用日期分目录应写 {date:yyyy}/{date:MM}；格式串内部的 "/" 是数据，清洗为 "-"
        let result = resolver.resolve("{date:yyyy/MM}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026-02")
    }

    func testTitle缺失回退原文件名() {
        var meta = metadata
        meta.title = nil
        let result = resolver.resolve("{title}", metadata: meta, fallbackName: "原名")
        XCTAssertEqual(result, "原名")
    }

    func test其余令牌缺失为空串() {
        var meta = metadata
        meta.source = nil
        let result = resolver.resolve("{title}-{source}", metadata: meta, fallbackName: "原名")
        XCTAssertEqual(result, "三月增值税发票-")
    }

    func test令牌值中的斜杠被清洗_模板中的斜杠保留() {
        // category 值内的 "/" 是数据，须清洗为 "-"；模板里显式写的 "/" 是子目录
        let result = resolver.resolve("{category}/{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "财务-发票/三月增值税发票")
    }

    func test未知令牌原样保留() {
        let result = resolver.resolve("{unknown}-{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "{unknown}-三月增值税发票")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'TemplateResolver'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Engine/TemplateResolver.swift`：

```swift
import Foundation

/// LLM（或本地提取）产出的元数据，供模板令牌引用（spec §4 LLM 动作）。
public struct ExtractedMetadata: Codable, Sendable, Equatable {
    public var title: String?
    public var date: Date?
    public var category: String?
    public var tags: [String]
    public var summary: String?
    public var source: String?

    public init(title: String? = nil, date: Date? = nil, category: String? = nil,
                tags: [String] = [], summary: String? = nil, source: String? = nil) {
        self.title = title
        self.date = date
        self.category = category
        self.tags = tags
        self.summary = summary
        self.source = source
    }
}

/// 命名模板解析：令牌替换 + 逐段文件名清洗。
/// 关键语义：模板级的 "/" 是子目录分隔符；令牌值内（含 {date:…} 格式串内）的 "/" 是数据，清洗为 "-"。
public struct TemplateResolver: Sendable {
    public init() {}

    public func resolve(_ template: String, metadata: ExtractedMetadata, fallbackName: String) -> String {
        // 1) 保护令牌：把 {…} 暂存为不含 "/" 的占位符，避免 {date:yyyy/MM} 这类格式串被误切段
        var protected = template
        var tokens: [String: String] = [:]
        var index = 0
        while let range = protected.range(of: #"\{[^}]*\}"#, options: .regularExpression) {
            let key = "\u{1}\(index)\u{1}"
            tokens[key] = String(protected[range])
            protected.replaceSubrange(range, with: key)
            index += 1
        }
        // 2) 按模板级 "/" 切段；3) 段内还原令牌、替换值、清洗
        return protected.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                var restored = String(segment)
                for (key, token) in tokens {
                    restored = restored.replacingOccurrences(of: key, with: token)
                }
                let substituted = substitute(restored, metadata: metadata, fallbackName: fallbackName)
                return sanitize(substituted)
            }
            .joined(separator: "/")
    }

    private func substitute(_ segment: String, metadata: ExtractedMetadata, fallbackName: String) -> String {
        var result = segment
        result = result.replacingOccurrences(of: "{title}", with: metadata.title ?? fallbackName)
        result = result.replacingOccurrences(of: "{category}", with: metadata.category ?? "")
        result = result.replacingOccurrences(of: "{source}", with: metadata.source ?? "")
        // {date:格式} 与 {date}
        while let range = result.range(of: #"\{date(:[^}]+)?\}"#, options: .regularExpression) {
            let token = String(result[range])
            let format: String
            if token == "{date}" {
                format = "yyyy-MM-dd"
            } else {
                format = String(token.dropFirst("{date:".count).dropLast())
            }
            result.replaceSubrange(range, with: formatted(metadata.date, format: format))
        }
        return result
    }

    private func formatted(_ date: Date?, format: String) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// 文件名单段清洗：路径分隔符与冒号替换为 "-"。
    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
```

说明：日期想分目录应写模板级的 `{date:yyyy}/{date:MM}`；格式串内部写 `/`（如 `{date:yyyy/MM}`）会被当作数据清洗为 `-`。这一点写进规则编辑器的令牌帮助文案（第 4/5 份计划处理）。

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter TemplateResolverTests`
Expected: PASS（7 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Engine Tests/SageTests/Engine
git commit -m "feat(sage): TemplateResolver 命名模板令牌解析"
```

---

### Task 9: RuleStore（规则库持久化）

**Files:**
- Create: `Sources/Sage/Store/RuleStore.swift`
- Test: `Tests/SageTests/Store/RuleStoreTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `Rule`。
- Produces:
  - `struct RuleLibrary: Codable, Sendable, Equatable` — `version: Int`（当前 `1`）、`rules: [Rule]`（数组顺序即匹配优先级）
  - `actor RuleStore`，`init(directory: URL)`（生产环境传 `~/Library/Application Support/Sage/`，测试传临时目录）
  - `func load() throws -> RuleLibrary`（文件不存在返回空库 `RuleLibrary(version: 1, rules: [])`；版本号大于当前抛 `RuleStoreError.unsupportedVersion`）
  - `func save(_ library: RuleLibrary) throws`（原子写 `rules.json`）
  - `enum RuleStoreError: LocalizedError` — `.unsupportedVersion(Int)`，中文 `errorDescription`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Store/RuleStoreTests.swift`：

```swift
import XCTest
@testable import Sage

final class RuleStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var sampleRule: Rule {
        Rule(id: UUID(), name: "发票归档", enabled: true,
             scopes: [.localFolder(path: "/in", recursive: true)],
             trigger: .automatic, conditionLogic: .all,
             conditions: [.fileExtension(.equals("pdf"))],
             actions: [.dtImport(database: "财务", groupPath: "/发票", tags: ["发票"], noteTemplate: nil)],
             executionMode: .confirmFirst)
    }

    func test文件不存在返回空库() async throws {
        let store = RuleStore(directory: tempDir)
        let library = try await store.load()
        XCTAssertEqual(library, RuleLibrary(version: 1, rules: []))
    }

    func test保存后读回_顺序保持() async throws {
        let store = RuleStore(directory: tempDir)
        var second = sampleRule
        second.id = UUID()
        second.name = "第二条"
        let library = RuleLibrary(version: 1, rules: [sampleRule, second])
        try await store.save(library)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, library)
        XCTAssertEqual(loaded.rules.map(\.name), ["发票归档", "第二条"])
    }

    func test不支持的版本抛错() async throws {
        let json = #"{"version": 99, "rules": []}"#
        try json.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("rules.json"))
        let store = RuleStore(directory: tempDir)
        do {
            _ = try await store.load()
            XCTFail("应当抛出 unsupportedVersion")
        } catch let error as RuleStoreError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription!.contains("99"))
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'RuleStore'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Store/RuleStore.swift`：

```swift
import Foundation

/// 规则库文件格式：带版本号，为将来迁移留余地（spec §10）。
public struct RuleLibrary: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var rules: [Rule] // 数组顺序即匹配优先级

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }
}

public enum RuleStoreError: LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "规则库文件版本 \(version) 高于当前应用支持的版本 \(RuleLibrary.currentVersion)，请升级 Sage。"
        }
    }
}

/// 规则库持久化（actor 串行读写）。
public actor RuleStore {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("rules.json")
    }

    public func load() throws -> RuleLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RuleLibrary(version: RuleLibrary.currentVersion, rules: [])
        }
        let data = try Data(contentsOf: fileURL)
        let library = try JSONDecoder().decode(RuleLibrary.self, from: data)
        guard library.version <= RuleLibrary.currentVersion else {
            throw RuleStoreError.unsupportedVersion(library.version)
        }
        return library
    }

    public func save(_ library: RuleLibrary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter RuleStoreTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: 全量回归并提交**

Run: `swift test --filter SageTests`
Expected: 全部通过（约 38 个测试）。

```bash
git add Sources/Sage/Store Tests/SageTests/Store
git commit -m "feat(sage): RuleStore 规则库持久化（版本化 JSON）"
```

---

## 后续计划衔接

本计划完成后，`Sage` 目标具备完整可测的规则求值核心。后续 4 份计划按序编写与执行：

2. **提取与 LLM 层**：实现真实 `FactsProvider`（Extraction 缓存 + LLMProvider/LLMGateway 限速/预算/降级），API Key 入 Keychain。
3. **监控与执行层**：FolderWatcher（FSEvents + 写入完成检测）、ManualIntake、ActionRunner、ConfirmQueue、Journal 回滚。
4. **UI 与应用形态**：规则中心主窗口、规则编辑器（含试运行）、确认队列、日志、设置、菜单栏常驻。
5. **DEVONthink 集成**：DTActions（AppleScript 转义）、DTWatcher 轮询、DT 回滚。
