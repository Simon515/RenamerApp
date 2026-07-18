# Sage 监控与执行层实施计划（第 3/5 份）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Sage 从「能算出该做什么」走到「真的把文件处理掉」：实现本地文件动作执行、操作日志与回滚、确认队列、文件夹监控（FSEvents + 写入完成检测）、手动录入，以及把事件→规则→执行串起来的编排协调器（全部 headless，UI 留给第 4 份）。

**Architecture:** 沿用已完成的 Domain + Engine + Extraction/LLM（分支 `feature/sage-core`，HEAD `23dbbc3`）。本计划新增 `Execution/`、`Watchers/`、`Pipeline/` 三个目录。执行层通过 `LocalActionExecutor` 处理本地/LLM 命名动作；DEVONthink 动作经 `DTActionExecutor` 协议留座，本计划提供抛「未实现」错误的占位实现，第 5 份计划替换为真实 AppleScript 实现。协调器 `Coordinator` 是 actor，把 `FileEvent` 喂给 `RuleEngine`，按 `requiresConfirmation` 路由到确认队列或直接执行，执行结果写入 `Journal`。

**Tech Stack:** Swift 6（StrictConcurrency）、Foundation、CoreServices（FSEvents）、CryptoKit（已有）、XCTest。macOS 14+。

## Global Constraints

- Swift tools 6.0；目标平台 `.macOS(.v14)`；`StrictConcurrency`。
- 可变状态用 `actor` 隔离；纯计算/值类型 `Sendable`。
- 持久化类型 `Codable`；JSON 文件带 `version` 字段（当前 `1`）。
- 自定义错误遵循 `LocalizedError` 并实现中文 `errorDescription`。
- 注释中文、标识符英文。
- 持久化统一放 `~/Library/Application Support/Sage/`；测试一律用临时目录，`tearDown` 清理。
- 写操作安全（spec §7）：目标已存在默认加序号后缀不覆盖；删除类动作（`.moveToTrash`）只允许经确认队列执行；`.move`/`rename` 记录到 Journal 以支持回滚。
- 复用现有类型，不重复定义：`Action`、`FileEvent`/`FileLocation`/`EventSource`、`ActionPlan`/`PlannedActions`、`Rule`、`RuleEngine(provider:)`、`TemplateResolver`、`ExtractedMetadata`、`ExtractionProvider`（`FactsProvider`）、`RuleStore`/`RuleLibrary`、`BoundedCache`。
- 已知环境限制：仅 CommandLineTools 的机器 `swift test` 报 `no such module 'XCTest'`；本机实测 XCTest 可用。每步先 `swift build`（红灯确认可加 `--build-tests`），测试用 `swift test --filter SageTests`（**切勿**跑全量 `swift test`——旧 `RenamerTests` 会挂起）。

## 现有接口速查（实现者可直接依赖）

```swift
// Domain/Action.swift
public enum Action { case moveTo(path:String); copyTo(path:String); rename(template:String)
    case addFinderTags([String]); moveToTrash
    case dtImport(database:String,groupPath:String,tags:[String],noteTemplate:String?)
    case dtRename(template:String); dtAddTags([String]); dtMoveToGroup(database:String,groupPath:String)
    case llmExtractMetadata; llmRename(instruction:String); continueMatching }

// Domain/FileEvent.swift
public enum FileLocation: Codable,Sendable,Equatable,Hashable { case local(path:String); devonthink(uuid:String,database:String,groupPath:String) }
public enum EventSource: Codable,Sendable,Equatable { case folderWatch(root:String); dtWatch(database:String,groupPath:String); manual }
public struct FileEvent: Sendable,Equatable { var location:FileLocation; var source:EventSource; init(location:,source:); func isCovered(by:RuleScope)->Bool }

// Domain/ActionPlan.swift
public struct PlannedActions: Sendable,Equatable { var ruleID:UUID; ruleName:String; location:FileLocation; actions:[Action]; requiresConfirmation:Bool }
public struct ActionPlan: Sendable,Equatable { var event:FileEvent; planned:[PlannedActions] }

// Engine/RuleEngine.swift
public struct RuleEngine: Sendable { init(provider: any FactsProvider); func plan(for:FileEvent, rules:[Rule]) async -> ActionPlan }

// Engine/TemplateResolver.swift
public struct ExtractedMetadata: Codable,Sendable,Equatable { var title:String?; date:Date?; category:String?; tags:[String]; summary:String?; source:String? }
public struct TemplateResolver: Sendable { init(); func resolve(_ template:String, metadata:ExtractedMetadata, fallbackName:String) -> String }

// Extraction/ExtractionProvider.swift  (是 FactsProvider)
public actor ExtractionProvider { init(extractor:LocalExtractor = .init(), gateway:LLMGateway, duplicateRegistry:DuplicateRegistry = .shared, cacheCapacity:Int = 500) }
```

---

### Task 1: 执行层 Domain 类型（JournalRecord / ReversibleOp / PendingItem / ActionOutcome）

**Files:**
- Create: `Sources/Sage/Domain/ExecutionRecords.swift`
- Test: `Tests/SageTests/Domain/ExecutionRecordsTests.swift`

**Interfaces:**
- Produces（后续任务全部依赖）：
  - `enum ReversibleOp: Codable, Sendable, Equatable` — 描述一步可回滚的文件系统变更：
    - `.moved(from: String, to: String)`
    - `.copied(to: String)`（回滚 = 删除副本）
    - `.renamed(from: String, to: String)`
    - `.trashed(originalPath: String, trashPath: String?)`（回滚 = 从 trashPath 移回，trashPath 为 nil 时无法自动回滚）
    - `.addedFinderTags([String], to: String, previous: [String])`（回滚 = 恢复 previous）
  - `struct JournalRecord: Codable, Sendable, Equatable, Identifiable` — `id: UUID`、`timestamp: Date`、`ruleID: UUID`、`ruleName: String`、`sourceDescription: String`（人类可读的源，如原路径）、`ops: [ReversibleOp]`（按执行顺序；回滚时逆序反做）
  - `struct PendingItem: Codable, Sendable, Equatable, Identifiable` — `id: UUID`、`enqueuedAt: Date`、`event: FileEventSnapshot`、`planned: PlannedActionsSnapshot`。因 `FileEvent`/`PlannedActions` 未声明 `Codable`，本文件同时定义可持久化快照：
    - `struct FileEventSnapshot: Codable, Sendable, Equatable` — `location: FileLocation`、`source: EventSourceSnapshot`，其中 `location` 复用已 Codable 的 `FileLocation`；`EventSourceSnapshot` 是 `EventSource` 的 Codable 镜像（`EventSource` 已 Codable，可直接复用——若可直接复用则无需镜像，见实现说明）
    - `struct PlannedActionsSnapshot: Codable, Sendable, Equatable` — `ruleID: UUID`、`ruleName: String`、`location: FileLocation`、`actions: [Action]`、`requiresConfirmation: Bool`
  - `enum ActionOutcome: Sendable, Equatable` — `.executed(JournalRecord)`、`.enqueued(PendingItem)`、`.failed(location: FileLocation, ruleName: String, message: String)`、`.skipped(reason: String)`

**实现说明：** `EventSource` 与 `FileLocation` 已是 `Codable`，`Action` 已是 `Codable`。因此 `PendingItem` 可直接持有 `FileEvent` 与 `PlannedActions` 的字段——但 `FileEvent`/`PlannedActions` 结构体本身未标 `Codable`。最省事且不改动已审查的 Domain 文件的做法：让 `FileEventSnapshot`/`PlannedActionsSnapshot` 直接持有 `FileLocation` + `EventSource` + `[Action]` 等已 Codable 字段并各自合成 Codable，再提供 `init(from: FileEvent)` / `var fileEvent: FileEvent` 与 `init(from: PlannedActions)` / `var plannedActions: PlannedActions` 转换。不要给 `FileEvent`/`PlannedActions` 追加 `Codable` 一致性（避免触碰已审查文件的公共协议）。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Domain/ExecutionRecordsTests.swift`：

```swift
import XCTest
@testable import Sage

final class ExecutionRecordsTests: XCTestCase {
    func testJournalRecord_Codable往返() throws {
        let record = JournalRecord(
            id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            ruleID: UUID(), ruleName: "发票归档", sourceDescription: "/in/a.pdf",
            ops: [.renamed(from: "/in/a.pdf", to: "/in/2026-发票.pdf"),
                  .moved(from: "/in/2026-发票.pdf", to: "/out/2026-发票.pdf")])
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(JournalRecord.self, from: data), record)
    }

    func testPendingItem_从FileEvent与PlannedActions构造并往返() throws {
        let event = FileEvent(location: .local(path: "/in/a.pdf"), source: .folderWatch(root: "/in"))
        let planned = PlannedActions(ruleID: UUID(), ruleName: "R", location: .local(path: "/in/a.pdf"),
                                     actions: [.moveTo(path: "/out")], requiresConfirmation: true)
        let item = PendingItem(id: UUID(), enqueuedAt: Date(timeIntervalSince1970: 1),
                               event: FileEventSnapshot(from: event),
                               planned: PlannedActionsSnapshot(from: planned))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(PendingItem.self, from: data)
        XCTAssertEqual(decoded, item)
        // 快照可还原回领域类型
        XCTAssertEqual(decoded.event.fileEvent, event)
        XCTAssertEqual(decoded.planned.plannedActions, planned)
    }

    func testActionOutcome_Equatable() {
        let a = ActionOutcome.skipped(reason: "无匹配规则")
        let b = ActionOutcome.skipped(reason: "无匹配规则")
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'JournalRecord'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Domain/ExecutionRecords.swift`：

```swift
import Foundation

/// 一步可逆的文件系统变更；回滚时逆序反做。
public enum ReversibleOp: Codable, Sendable, Equatable {
    case moved(from: String, to: String)
    case copied(to: String)
    case renamed(from: String, to: String)
    case trashed(originalPath: String, trashPath: String?)
    case addedFinderTags([String], to: String, previous: [String])
}

/// 一次成功执行的操作记录（用于日志展示与回滚）。
public struct JournalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var ruleID: UUID
    public var ruleName: String
    public var sourceDescription: String
    public var ops: [ReversibleOp]

    public init(id: UUID, timestamp: Date, ruleID: UUID, ruleName: String,
                sourceDescription: String, ops: [ReversibleOp]) {
        self.id = id; self.timestamp = timestamp; self.ruleID = ruleID
        self.ruleName = ruleName; self.sourceDescription = sourceDescription; self.ops = ops
    }
}

/// FileEvent 的可持久化快照（FileEvent 本身未声明 Codable，不改动已审查的 Domain 文件）。
public struct FileEventSnapshot: Codable, Sendable, Equatable {
    public var location: FileLocation
    public var source: EventSource

    public init(location: FileLocation, source: EventSource) {
        self.location = location; self.source = source
    }
    public init(from event: FileEvent) { self.init(location: event.location, source: event.source) }
    public var fileEvent: FileEvent { FileEvent(location: location, source: source) }
}

/// PlannedActions 的可持久化快照。
public struct PlannedActionsSnapshot: Codable, Sendable, Equatable {
    public var ruleID: UUID
    public var ruleName: String
    public var location: FileLocation
    public var actions: [Action]
    public var requiresConfirmation: Bool

    public init(ruleID: UUID, ruleName: String, location: FileLocation,
                actions: [Action], requiresConfirmation: Bool) {
        self.ruleID = ruleID; self.ruleName = ruleName; self.location = location
        self.actions = actions; self.requiresConfirmation = requiresConfirmation
    }
    public init(from p: PlannedActions) {
        self.init(ruleID: p.ruleID, ruleName: p.ruleName, location: p.location,
                  actions: p.actions, requiresConfirmation: p.requiresConfirmation)
    }
    public var plannedActions: PlannedActions {
        PlannedActions(ruleID: ruleID, ruleName: ruleName, location: location,
                       actions: actions, requiresConfirmation: requiresConfirmation)
    }
}

/// 待确认队列中的一项。
public struct PendingItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enqueuedAt: Date
    public var event: FileEventSnapshot
    public var planned: PlannedActionsSnapshot

    public init(id: UUID, enqueuedAt: Date, event: FileEventSnapshot, planned: PlannedActionsSnapshot) {
        self.id = id; self.enqueuedAt = enqueuedAt; self.event = event; self.planned = planned
    }
}

/// 单条 PlannedActions 处理后的结果。
public enum ActionOutcome: Sendable, Equatable {
    case executed(JournalRecord)
    case enqueued(PendingItem)
    case failed(location: FileLocation, ruleName: String, message: String)
    case skipped(reason: String)
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ExecutionRecordsTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Domain/ExecutionRecords.swift Tests/SageTests/Domain/ExecutionRecordsTests.swift
git commit -m "feat(sage): 执行层 Domain 类型 JournalRecord/PendingItem/ReversibleOp"
```

---

### Task 2: 目标路径解析（TargetPathResolver，模板 + 目录 + 防重名）

**Files:**
- Create: `Sources/Sage/Execution/TargetPathResolver.swift`
- Test: `Tests/SageTests/Execution/TargetPathResolverTests.swift`

**Interfaces:**
- Consumes: `TemplateResolver`、`ExtractedMetadata`。
- Produces:
  - `struct TargetPathResolver: Sendable`，`init(templateResolver: TemplateResolver = TemplateResolver(), fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })`
  - `func resolveDestination(baseDirectory: String, template: String, sourceName: String, metadata: ExtractedMetadata) -> String` — 用 `TemplateResolver` 得到相对名（可含 `/` 子目录），拼到 `baseDirectory` 下，保留源文件扩展名（模板结果不含扩展名时补上 `sourceName` 的扩展名），并对整体路径做防重名：已存在则在**文件名主干**后加 ` 2`、` 3`…（不动扩展名与目录）。
  - `func resolveRename(inDirectoryOf sourcePath: String, template: String, metadata: ExtractedMetadata) -> String` — 同目录内重命名，返回新绝对路径，同样防重名。

**语义要点：** 扩展名取 `sourceName` 中最后一个 `.` 之后部分（无扩展名则不补）。防重名从 2 起编号，跳过已存在的编号。`sourceName` 用作模板 `{title}` 缺失时的回退（去掉扩展名的主干）。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Execution/TargetPathResolverTests.swift`：

```swift
import XCTest
@testable import Sage

final class TargetPathResolverTests: XCTestCase {
    private func meta(title: String?) -> ExtractedMetadata { ExtractedMetadata(title: title) }

    func test基本目标路径_补源扩展名() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "扫描件.pdf", metadata: meta(title: "发票2026"))
        XCTAssertEqual(path, "/out/发票2026.pdf")
    }

    func test模板含子目录() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "a.pdf", metadata: meta(title: "财务/发票"))
        // TemplateResolver 会把令牌值内的 "/" 清洗为 "-"，故不产生子目录
        XCTAssertEqual(path, "/out/财务-发票.pdf")
    }

    func testTitle缺失回退源文件主干() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "原始名.jpg", metadata: meta(title: nil))
        XCTAssertEqual(path, "/out/原始名.jpg")
    }

    func test防重名_加序号跳过已存在() {
        let taken: Set<String> = ["/out/发票.pdf", "/out/发票 2.pdf"]
        let resolver = TargetPathResolver(fileExists: { taken.contains($0) })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "x.pdf", metadata: meta(title: "发票"))
        XCTAssertEqual(path, "/out/发票 3.pdf")
    }

    func testRename同目录() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveRename(inDirectoryOf: "/in/sub/old.pdf", template: "{title}",
                                          metadata: meta(title: "新名"))
        XCTAssertEqual(path, "/in/sub/新名.pdf")
    }

    func test无扩展名不补点() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "README", metadata: meta(title: "读我"))
        XCTAssertEqual(path, "/out/读我")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'TargetPathResolver'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Execution/TargetPathResolver.swift`：

```swift
import Foundation

/// 目标路径解析：模板求值 → 拼目录 → 补扩展名 → 防重名。
public struct TargetPathResolver: Sendable {
    private let templateResolver: TemplateResolver
    private let fileExists: @Sendable (String) -> Bool

    public init(templateResolver: TemplateResolver = TemplateResolver(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.templateResolver = templateResolver
        self.fileExists = fileExists
    }

    public func resolveDestination(baseDirectory: String, template: String,
                                   sourceName: String, metadata: ExtractedMetadata) -> String {
        let (stem, ext) = splitExtension(sourceName)
        let resolved = templateResolver.resolve(template, metadata: metadata, fallbackName: stem)
        let named = appendExtension(resolved, ext: ext)
        let full = (baseDirectory as NSString).appendingPathComponent(named)
        return deduplicate(full)
    }

    public func resolveRename(inDirectoryOf sourcePath: String, template: String,
                              metadata: ExtractedMetadata) -> String {
        let dir = (sourcePath as NSString).deletingLastPathComponent
        let sourceName = (sourcePath as NSString).lastPathComponent
        return resolveDestination(baseDirectory: dir, template: template,
                                  sourceName: sourceName, metadata: metadata)
    }

    /// 拆出主干与扩展名（无扩展名时 ext 为 nil）。
    private func splitExtension(_ name: String) -> (stem: String, ext: String?) {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return (name, nil) }
        return (ns.deletingPathExtension, ext)
    }

    private func appendExtension(_ name: String, ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return name }
        return "\(name).\(ext)"
    }

    /// 已存在则在主干后加 " 2"、" 3"…（保留扩展名）。
    private func deduplicate(_ path: String) -> String {
        guard fileExists(path) else { return path }
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let fileName = ns.lastPathComponent
        let (stem, ext) = splitExtension(fileName)
        var index = 2
        while true {
            let candidateName = appendExtension("\(stem) \(index)", ext: ext)
            let candidate = (dir as NSString).appendingPathComponent(candidateName)
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter TargetPathResolverTests`
Expected: PASS（6 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Execution/TargetPathResolver.swift Tests/SageTests/Execution/TargetPathResolverTests.swift
git commit -m "feat(sage): TargetPathResolver 目标路径解析与防重名"
```

---

### Task 3: 元数据供给协议与 LocalActionExecutor（本地/LLM 命名动作）

**Files:**
- Create: `Sources/Sage/Execution/ActionExecuting.swift`
- Create: `Sources/Sage/Execution/LocalActionExecutor.swift`
- Create: `Tests/SageTests/Support/FakeMetadataProvider.swift`
- Test: `Tests/SageTests/Execution/LocalActionExecutorTests.swift`

**Interfaces:**
- Consumes: `Action`、`FileLocation`、`ExtractedMetadata`、`ReversibleOp`、`TargetPathResolver`。
- Produces:
  - `protocol MetadataProviding: Sendable { func metadata(for location: FileLocation) async throws -> ExtractedMetadata }`（真实实现在 Task 10 用 `ExtractionProvider` + `LLMGateway` 适配；测试用 `FakeMetadataProvider`）
  - `enum ActionExecutionError: LocalizedError` — `.notLocalFile`、`.unsupportedAction(String)`、`.sourceMissing(String)`、`.finderTagsFailed(String)`，均中文 `errorDescription`
  - `protocol DTActionExecutor: Sendable { func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp] }`（DEVONthink 动作留座；本计划提供 `UnimplementedDTActionExecutor` 抛 `.unsupportedAction`）
  - `struct UnimplementedDTActionExecutor: DTActionExecutor`
  - `actor LocalActionExecutor`，`init(metadataProvider: any MetadataProviding, pathResolver: TargetPathResolver = TargetPathResolver(), fileManager: FileManager = .default, dtExecutor: any DTActionExecutor = UnimplementedDTActionExecutor())`
  - `func run(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp]` — 顺序执行动作，维护「当前文件位置」（move/rename 后位置改变）与「累计元数据」（`.llmExtractMetadata` 拉取并缓存，供后续 `rename`/`llmRename` 的模板/指令使用），返回全部 `ReversibleOp`。遇 `.moveToTrash` 抛错（本 executor 不执行删除——删除只走确认队列的专门路径，见 Task 6 说明中的约定：删除动作在 Coordinator 层被强制入队，执行时才由本 executor 的 `runIncludingTrash` 处理）。`.continueMatching` 忽略（它只影响匹配，不是执行动作）。DT 动作转交 `dtExecutor`。
  - `func runIncludingTrash(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp]` — 与 `run` 相同，但允许 `.moveToTrash`（移到废纸篓并记录 `.trashed`）。Coordinator 对确认后执行调用此方法。

**语义要点：**
- `startLocation` 必须是 `.local(path:)`，否则抛 `.notLocalFile`（DT 位置在本计划不由本 executor 直接处理）。
- `moveTo(path:)`：`path` 是目标**目录**，用 `TargetPathResolver.resolveDestination` 以 `{title}` 缺省模板？不——`moveTo` 不改名，直接把文件移动到该目录下、保留原名，防重名。`rename` 才用模板。
- `copyTo(path:)`：复制到目标目录，保留原名，防重名，记 `.copied(to:)`；复制不改变「当前位置」（后续动作仍作用于原文件）。
- `rename(template:)`：在**当前目录**内按模板重命名，记 `.renamed(from:to:)`，更新当前位置。
- `llmRename(instruction:)`：把 `instruction` 作为模板同样处理（v2.0 简化：指令即模板；真正的自然语言命名在 LLM 提取的 metadata.title 基础上，指令作为模板字符串）。记 `.renamed`，更新当前位置。
- `llmExtractMetadata`：调用 `metadataProvider.metadata(for:)` 存入累计元数据，不产生 `ReversibleOp`。
- `addFinderTags`：读取当前 Finder 标签（`URLResourceValues.tagNames`），并集写回，记 `.addedFinderTags(new, to:, previous:)`。

- [ ] **Step 1: 写测试基建**

`Tests/SageTests/Support/FakeMetadataProvider.swift`：

```swift
import Foundation
@testable import Sage

final class FakeMetadataProvider: MetadataProviding, @unchecked Sendable {
    var result: ExtractedMetadata
    private(set) var calls = 0
    init(result: ExtractedMetadata) { self.result = result }
    func metadata(for location: FileLocation) async throws -> ExtractedMetadata {
        calls += 1
        return result
    }
}
```

- [ ] **Step 2: 写失败测试**

`Tests/SageTests/Execution/LocalActionExecutorTests.swift`：

```swift
import XCTest
@testable import Sage

final class LocalActionExecutorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageExec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String, _ contents: String = "x") throws -> String {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func test移动到目录_保留原名() async throws {
        let src = try makeFile("a.pdf")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        let ops = try await exec.run(actions: [.moveTo(path: outDir.path)], on: .local(path: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
        XCTAssertEqual(ops.count, 1)
    }

    func test重命名用元数据模板() async throws {
        let src = try makeFile("scan.pdf")
        let provider = FakeMetadataProvider(result: .init(title: "发票2026"))
        let exec = LocalActionExecutor(metadataProvider: provider)
        let ops = try await exec.run(actions: [.llmExtractMetadata, .rename(template: "{title}")],
                                     on: .local(path: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("发票2026.pdf").path))
        XCTAssertEqual(provider.calls, 1)
        XCTAssertTrue(ops.contains(.renamed(from: src, to: dir.appendingPathComponent("发票2026.pdf").path)))
    }

    func test复制不改变当前位置_后续动作仍作用原文件() async throws {
        let src = try makeFile("a.txt")
        let copyDir = dir.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init(title: "改名")))
        _ = try await exec.run(actions: [.copyTo(path: copyDir.path), .rename(template: "{title}")],
                               on: .local(path: src))
        // 副本仍叫 a.txt，原文件被改名为 改名.txt
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyDir.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("改名.txt").path))
    }

    func test非本地位置抛错() async {
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        do {
            _ = try await exec.run(actions: [.moveTo(path: "/out")],
                                   on: .devonthink(uuid: "X", database: "D", groupPath: "/G"))
            XCTFail("应抛 notLocalFile")
        } catch let e as ActionExecutionError {
            XCTAssertNotNil(e.errorDescription)
        }
    }

    func test废纸篓仅runIncludingTrash允许() async throws {
        let src = try makeFile("del.txt")
        let exec = LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init()))
        // run 拒绝 trash
        do { _ = try await exec.run(actions: [.moveToTrash], on: .local(path: src)); XCTFail() }
        catch let e as ActionExecutionError { XCTAssertNotNil(e.errorDescription) }
        // runIncludingTrash 执行
        let ops = try await exec.runIncludingTrash(actions: [.moveToTrash], on: .local(path: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
        if case .trashed = ops.first {} else { XCTFail("应记 trashed") }
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'LocalActionExecutor'`。

- [ ] **Step 4: 实现**

`Sources/Sage/Execution/ActionExecuting.swift`：

```swift
import Foundation

/// 为 LLM 命名动作提供文件元数据。
public protocol MetadataProviding: Sendable {
    func metadata(for location: FileLocation) async throws -> ExtractedMetadata
}

/// DEVONthink 动作执行留座（真实实现在第 5 份计划）。
public protocol DTActionExecutor: Sendable {
    func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp]
}

public enum ActionExecutionError: LocalizedError {
    case notLocalFile
    case unsupportedAction(String)
    case sourceMissing(String)
    case finderTagsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLocalFile: return "该动作只能作用于本地文件。"
        case .unsupportedAction(let name): return "动作「\(name)」在当前版本尚未支持执行。"
        case .sourceMissing(let path): return "源文件不存在：\(path)"
        case .finderTagsFailed(let msg): return "写入 Finder 标签失败：\(msg)"
        }
    }
}

/// DEVONthink 动作在本计划未实现，一律抛错（第 5 份计划替换）。
public struct UnimplementedDTActionExecutor: DTActionExecutor {
    public init() {}
    public func execute(_ action: Action, at location: FileLocation) async throws -> [ReversibleOp] {
        throw ActionExecutionError.unsupportedAction("DEVONthink 动作")
    }
}
```

`Sources/Sage/Execution/LocalActionExecutor.swift`：

```swift
import Foundation

/// 本地文件系统动作执行器（actor：写操作串行）。
public actor LocalActionExecutor {
    private let metadataProvider: any MetadataProviding
    private let pathResolver: TargetPathResolver
    private let fileManager: FileManager
    private let dtExecutor: any DTActionExecutor

    public init(metadataProvider: any MetadataProviding,
                pathResolver: TargetPathResolver = TargetPathResolver(),
                fileManager: FileManager = .default,
                dtExecutor: any DTActionExecutor = UnimplementedDTActionExecutor()) {
        self.metadataProvider = metadataProvider
        self.pathResolver = pathResolver
        self.fileManager = fileManager
        self.dtExecutor = dtExecutor
    }

    public func run(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp] {
        try await execute(actions: actions, on: startLocation, allowTrash: false)
    }

    public func runIncludingTrash(actions: [Action], on startLocation: FileLocation) async throws -> [ReversibleOp] {
        try await execute(actions: actions, on: startLocation, allowTrash: true)
    }

    private func execute(actions: [Action], on startLocation: FileLocation,
                         allowTrash: Bool) async throws -> [ReversibleOp] {
        guard case .local(var currentPath) = startLocation else { throw ActionExecutionError.notLocalFile }
        var ops: [ReversibleOp] = []
        var metadata = ExtractedMetadata()

        for action in actions {
            switch action {
            case .continueMatching:
                continue
            case .llmExtractMetadata:
                metadata = try await metadataProvider.metadata(for: .local(path: currentPath))
            case .moveTo(let destDir):
                let name = (currentPath as NSString).lastPathComponent
                let dest = dedupInDir(destDir, name: name)
                try move(from: currentPath, to: dest)
                ops.append(.moved(from: currentPath, to: dest))
                currentPath = dest
            case .copyTo(let destDir):
                let name = (currentPath as NSString).lastPathComponent
                let dest = dedupInDir(destDir, name: name)
                try fileManager.copyItem(atPath: currentPath, toPath: dest)
                ops.append(.copied(to: dest))
            case .rename(let template):
                let dest = pathResolver.resolveRename(inDirectoryOf: currentPath, template: template, metadata: metadata)
                try move(from: currentPath, to: dest)
                ops.append(.renamed(from: currentPath, to: dest))
                currentPath = dest
            case .llmRename(let instruction):
                let dest = pathResolver.resolveRename(inDirectoryOf: currentPath, template: instruction, metadata: metadata)
                try move(from: currentPath, to: dest)
                ops.append(.renamed(from: currentPath, to: dest))
                currentPath = dest
            case .addFinderTags(let tags):
                let op = try addFinderTags(tags, to: currentPath)
                ops.append(op)
            case .moveToTrash:
                guard allowTrash else { throw ActionExecutionError.unsupportedAction("移到废纸篓（需经确认队列）") }
                let op = try trash(currentPath)
                ops.append(op)
                return ops // 文件已入废纸篓，后续动作无意义
            case .dtImport, .dtRename, .dtAddTags, .dtMoveToGroup:
                let dtOps = try await dtExecutor.execute(action, at: .local(path: currentPath))
                ops.append(contentsOf: dtOps)
            }
        }
        return ops
    }

    private func move(from: String, to: String) throws {
        guard fileManager.fileExists(atPath: from) else { throw ActionExecutionError.sourceMissing(from) }
        try fileManager.moveItem(atPath: from, toPath: to)
    }

    private func dedupInDir(_ dir: String, name: String) -> String {
        let full = (dir as NSString).appendingPathComponent(name)
        guard fileManager.fileExists(atPath: full) else { return full }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    private func addFinderTags(_ tags: [String], to path: String) throws -> ReversibleOp {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey])
            let previous = values.tagNames ?? []
            let merged = Array(Set(previous).union(tags)).sorted()
            var mutable = url
            var newValues = URLResourceValues()
            newValues.tagNames = merged
            try mutable.setResourceValues(newValues)
            return .addedFinderTags(merged, to: path, previous: previous)
        } catch {
            throw ActionExecutionError.finderTagsFailed(error.localizedDescription)
        }
    }

    private func trash(_ path: String) throws -> ReversibleOp {
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resulting)
        return .trashed(originalPath: path, trashPath: resulting?.path)
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift build && swift test --filter LocalActionExecutorTests`
Expected: PASS（5 个测试）。

- [ ] **Step 6: Commit**

```bash
git add Sources/Sage/Execution Tests/SageTests
git commit -m "feat(sage): LocalActionExecutor 本地/LLM 命名动作执行与 DT 留座"
```

---

### Task 4: Journal（操作日志持久化与回滚）

**Files:**
- Create: `Sources/Sage/Execution/Journal.swift`
- Test: `Tests/SageTests/Execution/JournalTests.swift`

**Interfaces:**
- Consumes: `JournalRecord`、`ReversibleOp`。
- Produces:
  - `struct JournalFile: Codable, Sendable, Equatable` — `version: Int`（当前 1）、`records: [JournalRecord]`
  - `actor Journal`，`init(directory: URL, fileManager: FileManager = .default, maxRecords: Int = 500)`
  - `func append(_ record: JournalRecord) throws` — 追加并按 `maxRecords` 截断最旧
  - `func all() throws -> [JournalRecord]` — 按时间倒序（最新在前）
  - `func rollback(id: UUID) throws` — 逆序反做该记录的 `ops`，成功后从日志移除；`.copied` 删副本、`.moved`/`.renamed` 反向移动、`.trashed` 从 trashPath 移回（nil 抛 `JournalError.cannotRollbackTrash`）、`.addedFinderTags` 恢复 previous
  - `enum JournalError: LocalizedError` — `.recordNotFound`、`.cannotRollbackTrash`、`.rollbackFailed(String)`，中文 `errorDescription`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Execution/JournalTests.swift`：

```swift
import XCTest
@testable import Sage

final class JournalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJournal-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func record(ops: [ReversibleOp], at date: Date) -> JournalRecord {
        JournalRecord(id: UUID(), timestamp: date, ruleID: UUID(), ruleName: "R",
                      sourceDescription: "s", ops: ops)
    }

    func test追加与倒序读取() async throws {
        let journal = Journal(directory: dir)
        let older = record(ops: [], at: Date(timeIntervalSince1970: 1))
        let newer = record(ops: [], at: Date(timeIntervalSince1970: 2))
        try await journal.append(older)
        try await journal.append(newer)
        let all = try await journal.all()
        XCTAssertEqual(all.map(\.id), [newer.id, older.id])
    }

    func test持久化跨实例() async throws {
        let r = record(ops: [], at: Date(timeIntervalSince1970: 1))
        try await Journal(directory: dir).append(r)
        let reloaded = try await Journal(directory: dir).all()
        XCTAssertEqual(reloaded.map(\.id), [r.id])
    }

    func test截断保留最新() async throws {
        let journal = Journal(directory: dir, maxRecords: 2)
        for i in 1...3 { try await journal.append(record(ops: [], at: Date(timeIntervalSince1970: TimeInterval(i)))) }
        let all = try await journal.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map { $0.timestamp.timeIntervalSince1970 }, [3, 2])
    }

    func test回滚move() async throws {
        let src = try makeFile("a.pdf")
        let dst = dir.appendingPathComponent("moved.pdf").path
        try FileManager.default.moveItem(atPath: src, toPath: dst)
        let journal = Journal(directory: dir)
        let r = record(ops: [.moved(from: src, to: dst)], at: Date())
        try await journal.append(r)
        try await journal.rollback(id: r.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        XCTAssertTrue(try await journal.all().isEmpty)
    }

    func test回滚copy删副本() async throws {
        let copy = try makeFile("copy.pdf")
        let journal = Journal(directory: dir)
        let r = record(ops: [.copied(to: copy)], at: Date())
        try await journal.append(r)
        try await journal.rollback(id: r.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    func test回滚trash无路径抛错() async throws {
        let journal = Journal(directory: dir)
        let r = record(ops: [.trashed(originalPath: "/x", trashPath: nil)], at: Date())
        try await journal.append(r)
        do { try await journal.rollback(id: r.id); XCTFail() }
        catch let e as JournalError { XCTAssertNotNil(e.errorDescription) }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'Journal'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Execution/Journal.swift`：

```swift
import Foundation

public struct JournalFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var records: [JournalRecord]
    public init(version: Int, records: [JournalRecord]) { self.version = version; self.records = records }
}

public enum JournalError: LocalizedError {
    case recordNotFound
    case cannotRollbackTrash
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound: return "找不到要回滚的操作记录。"
        case .cannotRollbackTrash: return "该文件已移入废纸篓且无记录的废纸篓路径，无法自动回滚，请手动从废纸篓恢复。"
        case .rollbackFailed(let msg): return "回滚失败：\(msg)"
        }
    }
}

/// 操作日志（actor：串行读写 + 回滚）。
public actor Journal {
    private let fileURL: URL
    private let fileManager: FileManager
    private let maxRecords: Int

    public init(directory: URL, fileManager: FileManager = .default, maxRecords: Int = 500) {
        self.fileURL = directory.appendingPathComponent("journal.json")
        self.fileManager = fileManager
        self.maxRecords = maxRecords
    }

    public func append(_ record: JournalRecord) throws {
        var file = try load()
        file.records.append(record)
        if file.records.count > maxRecords {
            file.records.removeFirst(file.records.count - maxRecords)
        }
        try save(file)
    }

    /// 时间倒序（最新在前）。
    public func all() throws -> [JournalRecord] {
        try load().records.sorted { $0.timestamp > $1.timestamp }
    }

    public func rollback(id: UUID) throws {
        var file = try load()
        guard let index = file.records.firstIndex(where: { $0.id == id }) else {
            throw JournalError.recordNotFound
        }
        let record = file.records[index]
        for op in record.ops.reversed() {
            try revert(op)
        }
        file.records.remove(at: index)
        try save(file)
    }

    private func revert(_ op: ReversibleOp) throws {
        switch op {
        case .moved(let from, let to), .renamed(let from, let to):
            try moveBack(from: to, to: from)
        case .copied(let to):
            if fileManager.fileExists(atPath: to) { try fileManager.removeItem(atPath: to) }
        case .trashed(let originalPath, let trashPath):
            guard let trashPath else { throw JournalError.cannotRollbackTrash }
            try moveBack(from: trashPath, to: originalPath)
        case .addedFinderTags(_, let path, let previous):
            let url = URL(fileURLWithPath: path)
            var mutable = url
            var values = URLResourceValues()
            values.tagNames = previous
            try? mutable.setResourceValues(values)
        }
    }

    private func moveBack(from: String, to: String) throws {
        guard fileManager.fileExists(atPath: from) else {
            throw JournalError.rollbackFailed("目标已不在原处：\(from)")
        }
        try fileManager.moveItem(atPath: from, toPath: to)
    }

    private func load() throws -> JournalFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return JournalFile(version: JournalFile.currentVersion, records: [])
        }
        return try JSONDecoder().decode(JournalFile.self, from: Data(contentsOf: fileURL))
    }

    private func save(_ file: JournalFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
```

`test回滚trash无路径抛错` 覆盖了 `.trashed` 的 nil 分支。

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter JournalTests`
Expected: PASS（6 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Execution/Journal.swift Tests/SageTests/Execution/JournalTests.swift
git commit -m "feat(sage): Journal 操作日志持久化与回滚"
```

---

### Task 5: ConfirmQueue（待确认队列持久化）

**Files:**
- Create: `Sources/Sage/Execution/ConfirmQueue.swift`
- Test: `Tests/SageTests/Execution/ConfirmQueueTests.swift`

**Interfaces:**
- Consumes: `PendingItem`。
- Produces:
  - `struct ConfirmQueueFile: Codable, Sendable, Equatable` — `version: Int`（1）、`items: [PendingItem]`
  - `actor ConfirmQueue`，`init(directory: URL, fileManager: FileManager = .default)`
  - `func enqueue(_ item: PendingItem) throws`
  - `func all() throws -> [PendingItem]`（入队顺序，最早在前）
  - `func item(id: UUID) throws -> PendingItem?`
  - `func remove(id: UUID) throws`（批准/拒绝后由调用方移除）
  - `func count() throws -> Int`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Execution/ConfirmQueueTests.swift`：

```swift
import XCTest
@testable import Sage

final class ConfirmQueueTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageQueue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ n: Int) -> PendingItem {
        let event = FileEvent(location: .local(path: "/in/\(n).pdf"), source: .manual)
        let planned = PlannedActions(ruleID: UUID(), ruleName: "R\(n)", location: .local(path: "/in/\(n).pdf"),
                                     actions: [.moveToTrash], requiresConfirmation: true)
        return PendingItem(id: UUID(), enqueuedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                           event: FileEventSnapshot(from: event), planned: PlannedActionsSnapshot(from: planned))
    }

    func test入队与顺序读取() async throws {
        let q = ConfirmQueue(directory: dir)
        let a = item(1); let b = item(2)
        try await q.enqueue(a); try await q.enqueue(b)
        XCTAssertEqual(try await q.all().map(\.id), [a.id, b.id])
        XCTAssertEqual(try await q.count(), 2)
    }

    func test持久化跨实例与按id查移() async throws {
        let a = item(1)
        try await ConfirmQueue(directory: dir).enqueue(a)
        let q2 = ConfirmQueue(directory: dir)
        XCTAssertEqual(try await q2.item(id: a.id)?.id, a.id)
        try await q2.remove(id: a.id)
        XCTAssertNil(try await q2.item(id: a.id))
        XCTAssertEqual(try await q2.count(), 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'ConfirmQueue'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Execution/ConfirmQueue.swift`：

```swift
import Foundation

public struct ConfirmQueueFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var items: [PendingItem]
    public init(version: Int, items: [PendingItem]) { self.version = version; self.items = items }
}

/// 待确认队列（actor：串行读写）。
public actor ConfirmQueue {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("confirm-queue.json")
        self.fileManager = fileManager
    }

    public func enqueue(_ item: PendingItem) throws {
        var file = try load()
        file.items.append(item)
        try save(file)
    }

    public func all() throws -> [PendingItem] {
        try load().items.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    public func item(id: UUID) throws -> PendingItem? {
        try load().items.first { $0.id == id }
    }

    public func remove(id: UUID) throws {
        var file = try load()
        file.items.removeAll { $0.id == id }
        try save(file)
    }

    public func count() throws -> Int { try load().items.count }

    private func load() throws -> ConfirmQueueFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ConfirmQueueFile(version: ConfirmQueueFile.currentVersion, items: [])
        }
        return try JSONDecoder().decode(ConfirmQueueFile.self, from: Data(contentsOf: fileURL))
    }

    private func save(_ file: ConfirmQueueFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ConfirmQueueTests`
Expected: PASS（2 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Execution/ConfirmQueue.swift Tests/SageTests/Execution/ConfirmQueueTests.swift
git commit -m "feat(sage): ConfirmQueue 待确认队列持久化"
```

---

### Task 6: WriteCompletionDebouncer（写入完成检测）

**Files:**
- Create: `Sources/Sage/Watchers/WriteCompletionDebouncer.swift`
- Test: `Tests/SageTests/Watchers/WriteCompletionDebouncerTests.swift`

**Interfaces:**
- Produces:
  - `protocol FileSizeReading: Sendable { func size(ofItemAt path: String) -> Int64? }`（size 为 nil 表示文件已不存在）
  - `struct DefaultFileSizeReader: FileSizeReading`（用 FileManager attributes）
  - `actor WriteCompletionDebouncer`，`init(stableWindow: TimeInterval = 2.0, pollInterval: TimeInterval = 0.5, sizeReader: any FileSizeReading = DefaultFileSizeReader(), sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })`
  - `func waitUntilStable(path: String, timeout: TimeInterval = 60) async -> Bool` — 轮询文件大小，连续 `stableWindow` 内大小不变则返回 true；文件消失返回 false；超过 timeout 返回 false（宁可不处理也不处理半截文件）。

**测试策略：** 注入假 `sizeReader`（按调用次数返回一串大小）与即时 `sleep`（不真实等待），断言稳定判定逻辑。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Watchers/WriteCompletionDebouncerTests.swift`：

```swift
import XCTest
@testable import Sage

private final class ScriptedSizeReader: FileSizeReading, @unchecked Sendable {
    private var sizes: [Int64?]
    private var index = 0
    init(_ sizes: [Int64?]) { self.sizes = sizes }
    func size(ofItemAt path: String) -> Int64? {
        defer { index = min(index + 1, sizes.count - 1) }
        return sizes[index]
    }
}

final class WriteCompletionDebouncerTests: XCTestCase {
    private let instantSleep: @Sendable (TimeInterval) async -> Void = { _ in }

    func test大小稳定后返回true() async {
        // 100 → 200 → 200 → 200：稳定窗口 2s / 轮询 0.5s 需连续 4 次不变，这里给足
        let reader = ScriptedSizeReader([100, 200, 200, 200, 200, 200, 200])
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 100)
        XCTAssertTrue(ok)
    }

    func test文件消失返回false() async {
        let reader = ScriptedSizeReader([100, nil])
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 100)
        XCTAssertFalse(ok)
    }

    func test持续增长直到超时返回false() async {
        // 每次都变大，永不稳定；timeout 很小，很快返回 false
        var n: Int64 = 0
        let reader = GrowingSizeReader { n += 100; return n }
        let d = WriteCompletionDebouncer(stableWindow: 1.0, pollInterval: 0.5,
                                         sizeReader: reader, sleep: instantSleep)
        let ok = await d.waitUntilStable(path: "/x", timeout: 2.0)
        XCTAssertFalse(ok)
    }
}

private final class GrowingSizeReader: FileSizeReading, @unchecked Sendable {
    private let next: @Sendable () -> Int64
    init(next: @escaping @Sendable () -> Int64) { self.next = next }
    func size(ofItemAt path: String) -> Int64? { next() }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'WriteCompletionDebouncer'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Watchers/WriteCompletionDebouncer.swift`：

```swift
import Foundation

public protocol FileSizeReading: Sendable {
    func size(ofItemAt path: String) -> Int64?
}

public struct DefaultFileSizeReader: FileSizeReading {
    public init() {}
    public func size(ofItemAt path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}

/// 写入完成检测：文件大小在 stableWindow 内不变才认为写完。
public actor WriteCompletionDebouncer {
    private let stableWindow: TimeInterval
    private let pollInterval: TimeInterval
    private let sizeReader: any FileSizeReading
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(stableWindow: TimeInterval = 2.0, pollInterval: TimeInterval = 0.5,
                sizeReader: any FileSizeReading = DefaultFileSizeReader(),
                sleep: @escaping @Sendable (TimeInterval) async -> Void = {
                    try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.stableWindow = stableWindow
        self.pollInterval = pollInterval
        self.sizeReader = sizeReader
        self.sleep = sleep
    }

    public func waitUntilStable(path: String, timeout: TimeInterval = 60) async -> Bool {
        guard var lastSize = sizeReader.size(ofItemAt: path) else { return false }
        var stableFor: TimeInterval = 0
        var elapsed: TimeInterval = 0
        while elapsed < timeout {
            await sleep(pollInterval)
            elapsed += pollInterval
            guard let size = sizeReader.size(ofItemAt: path) else { return false }
            if size == lastSize {
                stableFor += pollInterval
                if stableFor >= stableWindow { return true }
            } else {
                stableFor = 0
                lastSize = size
            }
        }
        return false
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter WriteCompletionDebouncerTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Watchers/WriteCompletionDebouncer.swift Tests/SageTests/Watchers/WriteCompletionDebouncerTests.swift
git commit -m "feat(sage): WriteCompletionDebouncer 写入完成检测"
```

---

### Task 7: ManualIntake（手动录入 → 批量事件）

**Files:**
- Create: `Sources/Sage/Watchers/ManualIntake.swift`
- Test: `Tests/SageTests/Watchers/ManualIntakeTests.swift`

**Interfaces:**
- Consumes: `FileEvent`。
- Produces:
  - `struct ManualIntake: Sendable`，`init(fileManager: FileManager = .default)`
  - `func events(forDroppedPaths paths: [String]) -> [FileEvent]` — 对每个路径：文件 → 一个 `.manual` 事件；目录 → 递归展开其下所有非隐藏文件各一个 `.manual` 事件（跳过以 `.` 开头的文件与目录）。去重（同一路径只产一个事件）。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Watchers/ManualIntakeTests.swift`：

```swift
import XCTest
@testable import Sage

final class ManualIntakeTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageIntake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func test单文件产一个事件() throws {
        try write("a.pdf")
        let events = ManualIntake().events(forDroppedPaths: [dir.appendingPathComponent("a.pdf").path])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.source, .manual)
    }

    func test目录递归展开跳过隐藏() throws {
        try write("a.pdf"); try write("sub/b.txt"); try write(".hidden"); try write(".git/c")
        let events = ManualIntake().events(forDroppedPaths: [dir.path])
        let names = Set(events.compactMap { loc -> String? in
            if case .local(let p) = loc.location { return (p as NSString).lastPathComponent }
            return nil
        })
        XCTAssertEqual(names, ["a.pdf", "b.txt"])
    }

    func test去重() throws {
        try write("a.pdf")
        let p = dir.appendingPathComponent("a.pdf").path
        let events = ManualIntake().events(forDroppedPaths: [p, p])
        XCTAssertEqual(events.count, 1)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'ManualIntake'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Watchers/ManualIntake.swift`：

```swift
import Foundation

/// 手动拖入/选择 → 一次性批量 FileEvent（source = .manual）。
public struct ManualIntake: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func events(forDroppedPaths paths: [String]) -> [FileEvent] {
        var seen = Set<String>()
        var result: [FileEvent] = []
        for path in paths {
            for filePath in expand(path) where seen.insert(filePath).inserted {
                result.append(FileEvent(location: .local(path: filePath), source: .manual))
            }
        }
        return result
    }

    /// 文件→自身；目录→递归所有非隐藏文件。
    private func expand(_ path: String) -> [String] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return [] }
        if !isDir.boolValue { return [path] }

        var files: [String] = []
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: []) else { return [] }
        for case let url as URL in enumerator {
            let comp = url.lastPathComponent
            if comp.hasPrefix(".") {
                // 跳过隐藏文件/目录（目录则不再深入）
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory { files.append(url.path) }
        }
        return files
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ManualIntakeTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Watchers/ManualIntake.swift Tests/SageTests/Watchers/ManualIntakeTests.swift
git commit -m "feat(sage): ManualIntake 手动录入批量事件"
```

---

### Task 8: Coordinator（事件 → 规则 → 路由执行/入队 → 日志）

**Files:**
- Create: `Sources/Sage/Pipeline/Coordinator.swift`
- Test: `Tests/SageTests/Pipeline/CoordinatorTests.swift`

**Interfaces:**
- Consumes: `RuleEngine`、`Rule`、`FileEvent`、`ActionPlan`/`PlannedActions`、`LocalActionExecutor`、`Journal`、`ConfirmQueue`、`ActionOutcome`、快照类型。
- Produces:
  - `protocol RulesProviding: Sendable { func currentRules() async -> [Rule] }`（Coordinator 每次处理事件时取最新规则；测试用固定实现，Task 10 用 `RuleStore` 适配）
  - `actor Coordinator`，`init(engine: RuleEngine, rulesProvider: any RulesProviding, executor: LocalActionExecutor, journal: Journal, confirmQueue: ConfirmQueue, now: @escaping @Sendable () -> Date = { Date() })`
  - `func handle(_ event: FileEvent) async -> [ActionOutcome]` — 取规则 → `engine.plan` → 对每个 `PlannedActions`：
    - `requiresConfirmation == true` → 构造 `PendingItem` 入 `ConfirmQueue`，产 `.enqueued`
    - 否则 → `executor.run(actions:on:)`，成功构造 `JournalRecord` 入 `Journal` 产 `.executed`，抛错产 `.failed`
    - `planned` 为空 → 返回单个 `.skipped(reason: "无匹配规则")`
  - `func approve(pendingID: UUID) async -> ActionOutcome` — 从队列取项 → `executor.runIncludingTrash` 执行（确认后允许删除）→ 成功写 Journal、移除队列项、产 `.executed`；失败产 `.failed`（不移除，便于重试）
  - `func reject(pendingID: UUID) async throws` — 从队列移除，不执行

**语义要点：** `JournalRecord.ops` 来自 executor 返回的 `[ReversibleOp]`；空 ops（例如仅 `addFinderTags` 也会有 op；若某规则动作全是 `.continueMatching`/`.llmExtractMetadata` 则 ops 为空）仍写一条记录以留痕。`sourceDescription` 用 location 的路径。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Pipeline/CoordinatorTests.swift`：

```swift
import XCTest
@testable import Sage

private struct FixedRules: RulesProviding {
    let rules: [Rule]
    func currentRules() async -> [Rule] { rules }
}

final class CoordinatorTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageCoord-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func rule(name: String, conditions: [Condition], actions: [Action],
                      mode: ExecutionMode) -> Rule {
        Rule(id: UUID(), name: name, enabled: true,
             scopes: [.localFolder(path: dir.path, recursive: true)],
             trigger: .automatic, conditionLogic: .all,
             conditions: conditions, actions: actions, executionMode: mode)
    }

    private func makeCoordinator(rules: [Rule]) -> Coordinator {
        let engine = RuleEngine(provider: FakeFactsProvider(
            cheap: CheapFacts(name: "a", fileExtension: "pdf", sizeBytes: 1)))
        return Coordinator(engine: engine, rulesProvider: FixedRules(rules: rules),
                           executor: LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init())),
                           journal: Journal(directory: dir), confirmQueue: ConfirmQueue(directory: dir))
    }

    func test自动规则_执行并写日志() async throws {
        let src = try makeFile("a.pdf")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let coord = makeCoordinator(rules: [
            rule(name: "移动", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveTo(path: outDir.path)], mode: .automatic)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .folderWatch(root: dir.path)))
        if case .executed = outcomes.first {} else { XCTFail("应 executed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
        // 日志有一条
        let journal = Journal(directory: dir)
        XCTAssertEqual(try await journal.all().count, 1)
    }

    func test确认模式_入队不执行() async throws {
        let src = try makeFile("a.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        if case .enqueued = outcomes.first {} else { XCTFail("应 enqueued") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src)) // 未删
        XCTAssertEqual(try await ConfirmQueue(directory: dir).count(), 1)
    }

    func test无匹配规则_skipped() async throws {
        let src = try makeFile("a.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "只匹配jpg", conditions: [.fileExtension(.equals("jpg"))],
                 actions: [.moveTo(path: "/out")], mode: .automatic)])
        let outcomes = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        if case .skipped = outcomes.first {} else { XCTFail("应 skipped") }
    }

    func test批准队列项_执行删除并出队() async throws {
        let src = try makeFile("del.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        _ = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        let queue = ConfirmQueue(directory: dir)
        let pending = try await queue.all().first!
        let outcome = await coord.approve(pendingID: pending.id)
        if case .executed = outcome {} else { XCTFail("应 executed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: src)) // 已删
        XCTAssertEqual(try await queue.count(), 0)
    }

    func test拒绝队列项_出队不执行() async throws {
        let src = try makeFile("keep.pdf")
        let coord = makeCoordinator(rules: [
            rule(name: "删除", conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveToTrash], mode: .confirmFirst)])
        _ = await coord.handle(FileEvent(location: .local(path: src), source: .manual))
        let queue = ConfirmQueue(directory: dir)
        let pending = try await queue.all().first!
        try await coord.reject(pendingID: pending.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src))
        XCTAssertEqual(try await queue.count(), 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'Coordinator'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Pipeline/Coordinator.swift`：

```swift
import Foundation

/// 为 Coordinator 提供当前规则集（每次处理事件时取最新）。
public protocol RulesProviding: Sendable {
    func currentRules() async -> [Rule]
}

/// 编排协调器：事件 → 规则匹配 → 路由（自动执行 / 入确认队列）→ 日志。
public actor Coordinator {
    private let engine: RuleEngine
    private let rulesProvider: any RulesProviding
    private let executor: LocalActionExecutor
    private let journal: Journal
    private let confirmQueue: ConfirmQueue
    private let now: @Sendable () -> Date

    public init(engine: RuleEngine, rulesProvider: any RulesProviding,
                executor: LocalActionExecutor, journal: Journal, confirmQueue: ConfirmQueue,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.rulesProvider = rulesProvider
        self.executor = executor
        self.journal = journal
        self.confirmQueue = confirmQueue
        self.now = now
    }

    public func handle(_ event: FileEvent) async -> [ActionOutcome] {
        let rules = await rulesProvider.currentRules()
        let plan = await engine.plan(for: event, rules: rules)
        guard !plan.planned.isEmpty else { return [.skipped(reason: "无匹配规则")] }

        var outcomes: [ActionOutcome] = []
        for planned in plan.planned {
            if planned.requiresConfirmation {
                let item = PendingItem(id: UUID(), enqueuedAt: now(),
                                       event: FileEventSnapshot(from: event),
                                       planned: PlannedActionsSnapshot(from: planned))
                do {
                    try await confirmQueue.enqueue(item)
                    outcomes.append(.enqueued(item))
                } catch {
                    outcomes.append(.failed(location: planned.location, ruleName: planned.ruleName,
                                            message: error.localizedDescription))
                }
            } else {
                outcomes.append(await execute(planned, includingTrash: false))
            }
        }
        return outcomes
    }

    public func approve(pendingID: UUID) async -> ActionOutcome {
        do {
            guard let item = try await confirmQueue.item(id: pendingID) else {
                return .failed(location: .local(path: ""), ruleName: "",
                               message: "队列中找不到该项。")
            }
            let outcome = await execute(item.planned.plannedActions, includingTrash: true)
            if case .executed = outcome {
                try await confirmQueue.remove(id: pendingID)
            }
            return outcome
        } catch {
            return .failed(location: .local(path: ""), ruleName: "",
                           message: error.localizedDescription)
        }
    }

    public func reject(pendingID: UUID) async throws {
        try await confirmQueue.remove(id: pendingID)
    }

    private func execute(_ planned: PlannedActions, includingTrash: Bool) async -> ActionOutcome {
        do {
            let ops = includingTrash
                ? try await executor.runIncludingTrash(actions: planned.actions, on: planned.location)
                : try await executor.run(actions: planned.actions, on: planned.location)
            let record = JournalRecord(id: UUID(), timestamp: now(), ruleID: planned.ruleID,
                                       ruleName: planned.ruleName,
                                       sourceDescription: describe(planned.location), ops: ops)
            try await journal.append(record)
            return .executed(record)
        } catch {
            return .failed(location: planned.location, ruleName: planned.ruleName,
                           message: error.localizedDescription)
        }
    }

    private func describe(_ location: FileLocation) -> String {
        switch location {
        case .local(let path): return path
        case .devonthink(_, let db, let group): return "DEVONthink:\(db)\(group)"
        }
    }
}
```

**说明：** 只有一个私有 `execute` 方法（接收 `PlannedActions`）。`handle` 对 `planned`（`PlannedActions`，来自 `plan.planned`）调 `execute(planned, includingTrash: false)`；`approve` 对 `item.planned.plannedActions`（快照还原的 `PlannedActions`）调 `execute(_:includingTrash: true)`。

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter CoordinatorTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Pipeline/Coordinator.swift Tests/SageTests/Pipeline/CoordinatorTests.swift
git commit -m "feat(sage): Coordinator 编排事件→规则→执行/入队→日志"
```

---

### Task 9: FolderWatcher（FSEvents 监控 + 防抖接入）

**Files:**
- Create: `Sources/Sage/Watchers/FolderWatcher.swift`
- Test: `Tests/SageTests/Watchers/FolderWatcherTests.swift`

**Interfaces:**
- Consumes: `FileEvent`、`WriteCompletionDebouncer`。
- Produces:
  - `protocol FileEventSource: AnyObject, Sendable { func start(); func stop() }`（监控源统一抽象）
  - `actor FolderWatcher: FileEventSource` 包装 FSEvents：`init(roots: [String], recursive: Bool, debouncer: WriteCompletionDebouncer = WriteCompletionDebouncer(), onEvent: @escaping @Sendable (FileEvent) async -> Void)`。`start()` 建 `FSEventStreamCreate` 监听 roots；回调里对每个新增/改名文件先 `debouncer.waitUntilStable`，稳定后调 `onEvent(FileEvent(location:.local(path:), source:.folderWatch(root:)))`。`stop()` 释放 stream。
  - 因 FSEvents 依赖 RunLoop、难以确定性单测，本任务的**自动化测试仅覆盖可隔离的纯逻辑**：`FolderWatcher.classify(paths:flags:)`——把 FSEvents 回调的路径+标志翻译为「需要处理的文件路径列表」的静态纯函数（过滤目录事件、删除事件、隐藏文件）。FSEvents 的实际接线（start/stop/回调）列入手动验证清单，不做自动化测试。

**说明：** 保持 FSEvents 特定代码尽量薄；`classify` 承担全部可测逻辑。手动验证清单写入本任务报告：①拖文件进被监控目录触发事件；②下载中的 .part 文件在完成前不触发（靠 debouncer）；③stop 后不再回调。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Watchers/FolderWatcherTests.swift`：

```swift
import XCTest
@testable import Sage

final class FolderWatcherTests: XCTestCase {
    func test分类_保留文件事件过滤删除与隐藏() {
        let paths = ["/w/a.pdf", "/w/.ds_store", "/w/gone.txt", "/w/sub/b.txt"]
        let flags: [FolderWatcher.EventFlag] = [
            [.isFile],                    // a.pdf 保留
            [.isFile],                    // .ds_store 隐藏，过滤
            [.isFile, .removed],          // gone.txt 已删除，过滤
            [.isFile],                    // b.txt 保留
        ]
        let result = FolderWatcher.classify(paths: paths, flags: flags)
        XCTAssertEqual(result, ["/w/a.pdf", "/w/sub/b.txt"])
    }

    func test分类_过滤目录事件() {
        let result = FolderWatcher.classify(paths: ["/w/dir"], flags: [[.isDir]])
        XCTAssertTrue(result.isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'FolderWatcher'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Watchers/FolderWatcher.swift`：

```swift
import Foundation
import CoreServices

/// 监控源统一抽象。
public protocol FileEventSource: AnyObject, Sendable {
    func start()
    func stop()
}

/// 本地文件夹监控（FSEvents）。FSEvents 接线薄，可测逻辑集中在 classify。
public final class FolderWatcher: FileEventSource, @unchecked Sendable {
    /// FSEvents 事件标志的精简镜像（便于纯逻辑测试）。
    public struct EventFlag: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let isFile = EventFlag(rawValue: 1 << 0)
        public static let isDir = EventFlag(rawValue: 1 << 1)
        public static let removed = EventFlag(rawValue: 1 << 2)
        public static let renamed = EventFlag(rawValue: 1 << 3)
    }

    private let roots: [String]
    private let recursive: Bool
    private let debouncer: WriteCompletionDebouncer
    private let onEvent: @Sendable (FileEvent) async -> Void
    private var stream: FSEventStreamRef?

    public init(roots: [String], recursive: Bool,
                debouncer: WriteCompletionDebouncer = WriteCompletionDebouncer(),
                onEvent: @escaping @Sendable (FileEvent) async -> Void) {
        self.roots = roots
        self.recursive = recursive
        self.debouncer = debouncer
        self.onEvent = onEvent
    }

    /// 把 FSEvents 回调的路径+标志翻译为需处理的文件路径（过滤目录/删除/隐藏）。
    public static func classify(paths: [String], flags: [EventFlag]) -> [String] {
        zip(paths, flags).compactMap { path, flag in
            guard flag.contains(.isFile) else { return nil }
            guard !flag.contains(.removed) else { return nil }
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            return path
        }
    }

    public func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathPtr = unsafeBitCast(paths, to: NSArray.self)
            var pathList: [String] = []
            var flagList: [EventFlag] = []
            for i in 0..<count {
                pathList.append((pathPtr[i] as? String) ?? "")
                flagList.append(watcher.translate(flags[i]))
            }
            let files = FolderWatcher.classify(paths: pathList, flags: flagList)
            let root = watcher.roots.first ?? ""
            for file in files {
                Task { [debouncer = watcher.debouncer, onEvent = watcher.onEvent] in
                    if await debouncer.waitUntilStable(path: file) {
                        await onEvent(FileEvent(location: .local(path: file), source: .folderWatch(root: root)))
                    }
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.5, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.jiyuliang.Sage.fsevents"))
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func translate(_ raw: FSEventStreamEventFlags) -> EventFlag {
        var flag: EventFlag = []
        if raw & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 { flag.insert(.isFile) }
        if raw & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { flag.insert(.isDir) }
        if raw & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { flag.insert(.removed) }
        if raw & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { flag.insert(.renamed) }
        return flag
    }
}
```

**并发说明：** `FolderWatcher` 用 `final class` + `@unchecked Sendable`，因为 FSEvents 需要一个稳定的 C 回调上下文指针；可变状态仅 `stream`（只在 start/stop 主动调用时读写，不与回调竞争）。回调内不改实例状态，只读 `roots`/`debouncer`/`onEvent`（均不可变或 Sendable）。

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter FolderWatcherTests`
Expected: PASS（2 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Watchers/FolderWatcher.swift Tests/SageTests/Watchers/FolderWatcherTests.swift
git commit -m "feat(sage): FolderWatcher FSEvents 监控与分类逻辑"
```

---

### Task 10: 组装 headless 核心（SageCore 适配器 + main 冒烟）

**Files:**
- Create: `Sources/Sage/Pipeline/ExtractionMetadataProvider.swift`
- Create: `Sources/Sage/Pipeline/RuleStoreRulesProvider.swift`
- Create: `Sources/Sage/Pipeline/SageCore.swift`
- Modify: `Sources/Sage/App/main.swift`
- Test: `Tests/SageTests/Pipeline/SageCoreTests.swift`

**Interfaces:**
- Consumes: 前面全部；`ExtractionProvider`、`LLMGateway`、`LLMPrompts`、`RuleStore`。
- Produces:
  - `struct ExtractionMetadataProvider: MetadataProviding` — 用 `ExtractionProvider` 取文本、`LLMGateway.extractMetadata` 产 `ExtractedMetadata`；`init(extraction: ExtractionProvider, gateway: LLMGateway, prompts: ...)`。若无文本或 LLM 失败则返回空 `ExtractedMetadata()`（降级不阻塞）。
  - `actor RuleStoreRulesProvider: RulesProviding` — 包 `RuleStore`，`currentRules()` 读 `load().rules`，读失败返回 `[]`。
  - `struct SageCore` — 组合根：`static func makeDefault(supportDirectory: URL, gateway: LLMGateway) -> (coordinator: Coordinator, rulesProvider: RuleStoreRulesProvider, manualIntake: ManualIntake)`，用默认目录装配 Coordinator/Journal/ConfirmQueue/Executor/Engine。
  - `main.swift`：构造 SageCore（用一个不发真实请求的占位 gateway 或跳过 LLM），打印装配成功，供冒烟。

**测试：** 端到端——建临时目录，`RuleStore` 存一条自动移动规则，`SageCore.makeDefault` 装配，`manualIntake.events` 造事件，`coordinator.handle` 执行，断言文件被移动、Journal 有记录。LLM 相关用 `FakeLLMProvider` 构造 gateway。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Pipeline/SageCoreTests.swift`：

```swift
import XCTest
@testable import Sage

final class SageCoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageCore-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test端到端_手动录入触发自动移动规则() async throws {
        // 源文件
        let inDir = dir.appendingPathComponent("in")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = inDir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)

        // 规则库：pdf → 移动到 out（手动作用域也覆盖，用 localFolder 递归 in）
        let store = RuleStore(directory: dir)
        let rule = Rule(id: UUID(), name: "移动PDF", enabled: true,
                        scopes: [.localFolder(path: inDir.path, recursive: true)],
                        trigger: .automatic, conditionLogic: .all,
                        conditions: [.fileExtension(.equals("pdf"))],
                        actions: [.moveTo(path: outDir.path)], executionMode: .automatic)
        try await store.save(RuleLibrary(version: 1, rules: [rule]))

        // gateway 用假 provider（本用例不触发 LLM）
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        let assembled = SageCore.makeDefault(supportDirectory: dir, gateway: gateway)

        let events = assembled.manualIntake.events(forDroppedPaths: [src.path])
        XCTAssertEqual(events.count, 1)
        let outcomes = await assembled.coordinator.handle(events[0])
        if case .executed = outcomes.first {} else { XCTFail("应 executed，实际 \(outcomes)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }
}
```

> 已核对签名（写计划时确认）：`LLMGateway(provider: LLMProvider, config: LLMGatewayConfig = .default, now:)`（预算在 config 内，无独立 budget 参数）；`FakeLLMProvider(content: String, delay: TimeInterval = 0)`；`RuleStore` 是 actor，`save(_:) throws` 与 `load() throws`（跨 actor 调用需 `try await`）。

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'SageCore'`。

- [ ] **Step 3: 实现**

先读 `Sources/Sage/LLM/LLMGateway.swift`、`Sources/Sage/LLM/LLMPrompts.swift`、`Sources/Sage/Extraction/ExtractionProvider.swift`、`Tests/SageTests/Support/FakeLLMProvider.swift`，据实际签名实现下述三个文件。

`Sources/Sage/Pipeline/ExtractionMetadataProvider.swift`：

```swift
import Foundation

/// 用提取层 + LLM 产出命名元数据；失败降级为空元数据，不阻塞执行。
public struct ExtractionMetadataProvider: MetadataProviding {
    private let extraction: ExtractionProvider
    private let gateway: LLMGateway

    public init(extraction: ExtractionProvider, gateway: LLMGateway) {
        self.extraction = extraction
        self.gateway = gateway
    }

    public func metadata(for location: FileLocation) async throws -> ExtractedMetadata {
        guard case .local(let path) = location else { return ExtractedMetadata() }
        let facts = (try? await extraction.extractedFacts(for: location))
        let text = facts?.text ?? ""
        guard !text.isEmpty else { return ExtractedMetadata() }
        let name = (path as NSString).lastPathComponent
        let request = LLMPrompts.extractMetadata(text: text, fallbackName: name)
        do {
            return try await gateway.extractMetadata(prompt: request.systemPrompt,
                                                     userPrompt: request.userPrompt,
                                                     cacheKey: facts?.contentHash ?? path)
        } catch {
            return ExtractedMetadata() // 降级
        }
    }
}
```

> 已核对：`LLMPrompts.extractMetadata(text:fallbackName:)` 返回 `LLMRequest`，其属性为 `systemPrompt` / `userPrompt` / `jsonSchemaHint`。`gateway.extractMetadata(prompt:userPrompt:cacheKey:)` 的首参标签是 `prompt`。

`Sources/Sage/Pipeline/RuleStoreRulesProvider.swift`：

```swift
import Foundation

/// 从 RuleStore 读取当前规则；读失败返回空（不阻塞管线）。
public actor RuleStoreRulesProvider: RulesProviding {
    private let store: RuleStore
    public init(store: RuleStore) { self.store = store }
    public func currentRules() async -> [Rule] {
        (try? await store.load())?.rules ?? []
    }
}
```

> 核对 `RuleStore` 是否有 `load()`（Task 9 第 1 份计划实现的是 `load() throws -> RuleLibrary`）。

`Sources/Sage/Pipeline/SageCore.swift`：

```swift
import Foundation

/// headless 组合根：装配监控/规则/执行/日志/队列。UI 在第 4 份计划接入。
public struct SageCore {
    public struct Assembled {
        public let coordinator: Coordinator
        public let rulesProvider: RuleStoreRulesProvider
        public let manualIntake: ManualIntake
    }

    public static func makeDefault(supportDirectory: URL, gateway: LLMGateway) -> Assembled {
        let extraction = ExtractionProvider(gateway: gateway)
        let engine = RuleEngine(provider: extraction)
        let metadataProvider = ExtractionMetadataProvider(extraction: extraction, gateway: gateway)
        let executor = LocalActionExecutor(metadataProvider: metadataProvider)
        let journal = Journal(directory: supportDirectory)
        let queue = ConfirmQueue(directory: supportDirectory)
        let store = RuleStore(directory: supportDirectory)
        let rulesProvider = RuleStoreRulesProvider(store: store)
        let coordinator = Coordinator(engine: engine, rulesProvider: rulesProvider,
                                      executor: executor, journal: journal, confirmQueue: queue)
        return Assembled(coordinator: coordinator, rulesProvider: rulesProvider,
                         manualIntake: ManualIntake())
    }
}
```

> 返回类型用嵌套 `Assembled` 结构（测试里以 `assembled.coordinator` 访问）。若偏好元组，与测试里的访问方式保持一致即可——以测试为准，这里统一用 `Assembled`。测试中的 `assembled.manualIntake` / `.coordinator` 访问与此一致。

`Sources/Sage/App/main.swift`（替换占位）：

```swift
import Foundation

// Sage headless 冒烟入口。GUI 与菜单栏形态在第 4 份计划实现。
let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sage", isDirectory: true)
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
print("Sage core assembled at \(support.path)")
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter SageCoreTests`
Expected: PASS（1 个测试）。若因 gateway/prompt 签名不符编译失败，按实际签名调整测试与 `ExtractionMetadataProvider`，直到通过。

- [ ] **Step 5: 全量 Sage 回归并提交**

Run: `swift test --filter SageTests`
Expected: 全部通过（本计划新增约 36 个测试，加上原有约 81 个）。

```bash
git add Sources/Sage Tests/SageTests
git commit -m "feat(sage): SageCore headless 组合根与端到端装配"
```

---

## 自检记录（写计划者已核对）

- **spec 覆盖**：本计划覆盖 spec §3 事件驱动流水线（Coordinator）、§4 本地/LLM 动作执行、§6 确认队列与日志的数据/逻辑层（UI 在第 4 份）、§7 执行安全（防重名、删除强制入队、写入完成检测、可回滚）、§8 错误处理（executor 抛错→`.failed`、LLM 降级→空元数据）。DEVONthink（§5）经 `DTActionExecutor` 留座，第 5 份计划实现。
- **未覆盖（有意，属后续计划）**：DTWatcher 与 DT 动作真实实现（第 5 份）、全部 UI/菜单栏/登录启动（第 4 份）、每日预算/限速的 UI 配置（第 4 份）。
- **类型一致性**：`ReversibleOp`、`JournalRecord`、`PendingItem`、快照类型在 Task 1 定义，Task 3/4/5/8 一致引用；`MetadataProviding` 在 Task 3 定义，Task 10 实现；`RulesProviding` 在 Task 8 定义，Task 10 实现；`DTActionExecutor` 在 Task 3 定义留座。
- **已知实现陷阱已在计划内标注**：Journal 的 `.trashed` 回滚分支修正、Coordinator 的 `execute` 重载删除、Task 10 的 LLM 签名需以现有代码为准。

## 后续计划衔接

- **第 4 份**：UI 与应用形态——规则中心主窗口、规则编辑器（含试运行）、确认队列视图、日志视图、设置、菜单栏常驻 + 登录启动。消费本计划的 Coordinator/Journal/ConfirmQueue/RuleStore。
- **第 5 份**：DEVONthink 集成——实现 `DTActionExecutor`（AppleScript 转义）、DTWatcher 轮询、DT 位置的 FactsProvider、DT 操作回滚。替换 `UnimplementedDTActionExecutor`。
