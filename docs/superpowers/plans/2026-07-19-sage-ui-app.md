# Sage 界面与应用形态实施计划（第 4/5 份）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已完成的引擎/提取/执行/监控层（Plans 1–3，已合并进 `main`）装成一个可用的 macOS 应用：规则中心主窗口、规则编辑器（含试运行）、确认队列、日志、设置、菜单栏常驻与登录启动。

**Architecture:** 分两层。**ViewModel 层**（`@MainActor @Observable`，纯逻辑，可 XCTest）承载全部状态与业务编排，依赖 Plans 1–3 的 actor（`Coordinator`/`Journal`/`ConfirmQueue`/`RuleStore`/`RuleEngine`）。**View 层**（SwiftUI + AppKit 菜单栏）只做渲染与用户输入转发，不含业务逻辑，采用「构建通过 + 手动验证清单」而非自动化测试（spec §9：UI 手动验证）。设置持久化沿用 `~/Library/Application Support/Sage/`，API Key 走 `SageKeychainStore`。

**Tech Stack:** Swift 6 StrictConcurrency、SwiftUI（`NavigationSplitView`、`MenuBarExtra`、`Window`、`Settings` scene）、AppKit（`NSApplication`/拖放）、ServiceManagement（`SMAppService` 登录启动）、XCTest。macOS 14+。

## Global Constraints

- Swift tools 6.0；`.macOS(.v14)`；Sage target 用 `enableExperimentalFeature("StrictConcurrency")`。
- ViewModel 一律 `@MainActor @Observable final class`；对 actor 的调用用 `await`；不在 View 里写业务逻辑。
- 持久化 JSON 带 `version` 字段（当前 `1`）；写 Application Support；测试用临时目录并在 `tearDown` 清理。
- API Key 只经 `SageKeychainStore`，绝不写入 settings.json。
- 自定义错误 `LocalizedError` + 中文 `errorDescription`；注释中文、标识符英文。
- 删除类动作（`.moveToTrash`）强制经确认队列——UI 不得提供绕过确认直接删除的入口。
- 测试命令用 `swift test --filter SageTests`（**切勿** `swift test`：旧 `RenamerTests` 会挂起）。构建用 `swift build`（GUI target）。
- View/菜单栏/App 入口任务：以 `swift build` 通过为完成门槛，并在报告中附带手动验证清单（无法自动化 GUI）。

## 现有接口速查（实现者可直接依赖，均已在 main 上）

```swift
// Pipeline/Coordinator.swift
public actor Coordinator {
    init(engine: RuleEngine, rulesProvider: any RulesProviding, executor: LocalActionExecutor,
         journal: Journal, confirmQueue: ConfirmQueue, now: @Sendable () -> Date = { Date() })
    func handle(_ event: FileEvent) async -> [ActionOutcome]
    func approve(pendingID: UUID) async -> ActionOutcome
    func reject(pendingID: UUID) async throws
}
public protocol RulesProviding: Sendable { func currentRules() async -> [Rule] }
// Pipeline/SageCore.swift
public struct SageCore {
    public struct Assembled { let coordinator: Coordinator; let rulesProvider: RuleStoreRulesProvider; let manualIntake: ManualIntake }
    static func makeDefault(supportDirectory: URL, gateway: LLMGateway) -> Assembled
}
public actor RuleStoreRulesProvider: RulesProviding { init(store: RuleStore) }

// Execution/Journal.swift
public actor Journal { init(directory: URL, fileManager: FileManager = .default, maxRecords: Int = 500)
    func append(_ record: JournalRecord) throws; func all() throws -> [JournalRecord]; func rollback(id: UUID) throws }
// Execution/ConfirmQueue.swift
public actor ConfirmQueue { init(directory: URL, fileManager: FileManager = .default)
    func enqueue(_ item: PendingItem) throws; func all() throws -> [PendingItem]
    func item(id: UUID) throws -> PendingItem?; func remove(id: UUID) throws; func count() throws -> Int }

// Store/RuleStore.swift
public actor RuleStore { init(directory: URL); func load() throws -> RuleLibrary; func save(_ library: RuleLibrary) throws }
public struct RuleLibrary: Codable, Sendable, Equatable { static let currentVersion = 1; var version: Int; var rules: [Rule] }

// Store/SageKeychainStore.swift
public struct SageKeychainStore: Sendable { init(service: String = "com.jiyuliang.Sage")
    func read(account: String) throws -> String?; func write(account: String, value: String) throws; func delete(account: String) throws }

// Domain
public struct Rule: Codable,Sendable,Equatable,Identifiable { var id:UUID; name:String; enabled:Bool; scopes:[RuleScope]
    trigger:TriggerMode; conditionLogic:ConditionLogic; conditions:[Condition]; actions:[Action]; executionMode:ExecutionMode
    var usesLLM:Bool; var requiresConfirmation:Bool }
public enum RuleScope { case localFolder(path:String,recursive:Bool); devonthink(database:String,groupPath:String); manualOnly }
public enum TriggerMode: String { case automatic; manualOnly }
public enum ConditionLogic: String { case all; any }
public enum ExecutionMode: String { case automatic; confirmFirst }
public enum Condition { case name(StringMatch); fileExtension(StringMatch); sizeBytes(min:Int64?,max:Int64?)
    createdWithinDays(Int); modifiedWithinDays(Int); utTypeConforms(String); textContent(StringMatch)
    isDuplicate; captureDateWithinDays(Int); sourceURL(StringMatch)
    contentBelongsTo(category:String,minConfidence:Double); contentMatchesDescription(String); var tier:CostTier }
public enum StringMatch { case equals(String); contains(String); regex(String); func matches(_:String)->Bool }
public enum Action { case moveTo(path:String); copyTo(path:String); rename(template:String); addFinderTags([String]); moveToTrash
    dtImport(...); dtRename(...); dtAddTags(...); dtMoveToGroup(...); llmExtractMetadata; llmRename(instruction:String); continueMatching; var usesLLM:Bool }
public struct FileEvent { init(location:FileLocation, source:EventSource) }
public enum FileLocation { case local(path:String); devonthink(uuid:,database:,groupPath:) }
public enum EventSource { case folderWatch(root:String); dtWatch(...); manual }
public enum ActionOutcome { case executed(JournalRecord); enqueued(PendingItem); failed(location:FileLocation,ruleName:String,message:String); skipped(reason:String) }
public struct JournalRecord: Identifiable { var id:UUID; timestamp:Date; ruleID:UUID; ruleName:String; sourceDescription:String; ops:[ReversibleOp] }
public struct PendingItem: Identifiable { var id:UUID; enqueuedAt:Date; event:FileEventSnapshot; planned:PlannedActionsSnapshot }
public struct PlannedActionsSnapshot { var ruleID:UUID; ruleName:String; location:FileLocation; actions:[Action]; requiresConfirmation:Bool; var plannedActions:PlannedActions }
public struct RuleEngine: Sendable { init(provider: any FactsProvider); func plan(for:FileEvent, rules:[Rule]) async -> ActionPlan }
public struct ActionPlan { var event:FileEvent; planned:[PlannedActions] }
public struct PlannedActions { var ruleID:UUID; ruleName:String; location:FileLocation; actions:[Action]; requiresConfirmation:Bool }

// LLM
public struct HTTPLLMConfig: Sendable { init(baseURL:URL, apiKey:String, model:String, timeout:TimeInterval = 30) }
public struct HTTPLLMProvider: LLMProvider { init(config: HTTPLLMConfig, session: URLSession = .shared) }
public struct LLMGatewayConfig: Sendable { var budget:LLMBudget; ...; init(budget:LLMBudget, minRetryDelay:=0.5, maxRetries:=3, minInterval:=0, cacheCapacity:=500) }
public struct LLMBudget: Sendable { init(dailyLimit:Int?, date:Date) }
public final class LLMGateway { init(provider:LLMProvider, config:LLMGatewayConfig = .default, now: @Sendable ()->Date = {Date()}) }
```

---

### Task 1: 设置模型与持久化（SageSettings + SettingsStore）

**Files:**
- Create: `Sources/Sage/Store/SageSettings.swift`
- Create: `Sources/Sage/Store/SettingsStore.swift`
- Test: `Tests/SageTests/Store/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: 无（纯新增）。API Key 由 `SageKeychainStore` 单独管理，不在此模型内。
- Produces:
  - `struct ProviderSettings: Codable, Sendable, Equatable` — `enabled: Bool`、`baseURL: String`、`model: String`、`timeoutSeconds: Double`（LLM 端点配置；API Key 不在此，存 Keychain）
  - `struct SageSettings: Codable, Sendable, Equatable` — `version: Int`（currentVersion=1）、`monitoringEnabled: Bool`、`launchAtLogin: Bool`、`dailyLLMBudget: Int?`（nil=不限）、`provider: ProviderSettings`。提供 `static var defaults: SageSettings`。
  - `actor SettingsStore` — `init(directory: URL, fileManager: FileManager = .default)`、`func load() throws -> SageSettings`（文件不存在返回 `.defaults`；version 高于当前抛错）、`func save(_ settings: SageSettings) throws`（原子写）。
  - `enum SettingsStoreError: LocalizedError` — `.unsupportedVersion(Int)`，中文 `errorDescription`。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Store/SettingsStoreTests.swift`：

```swift
import XCTest
@testable import Sage

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageSettings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test缺文件返回默认() async throws {
        let loaded = try await SettingsStore(directory: dir).load()
        XCTAssertEqual(loaded, SageSettings.defaults)
    }

    func test保存后加载往返() async throws {
        let store = SettingsStore(directory: dir)
        var s = SageSettings.defaults
        s.monitoringEnabled = false
        s.dailyLLMBudget = 200
        s.provider = ProviderSettings(enabled: true, baseURL: "https://api.deepseek.com/v1",
                                      model: "deepseek-chat", timeoutSeconds: 30)
        try await store.save(s)
        let reloaded = try await SettingsStore(directory: dir).load()
        XCTAssertEqual(reloaded, s)
    }

    func test高版本抛错() async throws {
        let future = #"{"version": 999, "monitoringEnabled": true, "launchAtLogin": false, "dailyLLMBudget": null, "provider": {"enabled": false, "baseURL": "", "model": "", "timeoutSeconds": 30}}"#
        try future.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        do { _ = try await SettingsStore(directory: dir).load(); XCTFail() }
        catch let e as SettingsStoreError { XCTAssertNotNil(e.errorDescription) }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'SettingsStore'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Store/SageSettings.swift`：

```swift
import Foundation

/// LLM 端点配置（API Key 不在此，存 Keychain）。
public struct ProviderSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var timeoutSeconds: Double

    public init(enabled: Bool, baseURL: String, model: String, timeoutSeconds: Double) {
        self.enabled = enabled; self.baseURL = baseURL; self.model = model; self.timeoutSeconds = timeoutSeconds
    }
}

/// 应用设置（持久化到 settings.json）。
public struct SageSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var monitoringEnabled: Bool
    public var launchAtLogin: Bool
    public var dailyLLMBudget: Int?
    public var provider: ProviderSettings

    public init(version: Int, monitoringEnabled: Bool, launchAtLogin: Bool,
                dailyLLMBudget: Int?, provider: ProviderSettings) {
        self.version = version; self.monitoringEnabled = monitoringEnabled
        self.launchAtLogin = launchAtLogin; self.dailyLLMBudget = dailyLLMBudget; self.provider = provider
    }

    public static var defaults: SageSettings {
        SageSettings(version: currentVersion, monitoringEnabled: true, launchAtLogin: false,
                     dailyLLMBudget: nil,
                     provider: ProviderSettings(enabled: false, baseURL: "", model: "", timeoutSeconds: 30))
    }
}
```

`Sources/Sage/Store/SettingsStore.swift`：

```swift
import Foundation

public enum SettingsStoreError: LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "设置文件版本 \(v) 高于当前应用支持的版本 \(SageSettings.currentVersion)，请升级 Sage。"
        }
    }
}

/// 设置持久化（actor：串行读写）。
public actor SettingsStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("settings.json")
        self.fileManager = fileManager
    }

    public func load() throws -> SageSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .defaults }
        let settings = try JSONDecoder().decode(SageSettings.self, from: Data(contentsOf: fileURL))
        guard settings.version <= SageSettings.currentVersion else {
            throw SettingsStoreError.unsupportedVersion(settings.version)
        }
        return settings
    }

    public func save(_ settings: SageSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter SettingsStoreTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Store/SageSettings.swift Sources/Sage/Store/SettingsStore.swift Tests/SageTests/Store/SettingsStoreTests.swift
git commit -m "feat(sage): SageSettings 设置模型与 SettingsStore 持久化"
```

---

### Task 2: 规则库视图模型（RuleListModel）

**Files:**
- Create: `Sources/Sage/ViewModels/RuleListModel.swift`
- Test: `Tests/SageTests/ViewModels/RuleListModelTests.swift`

**Interfaces:**
- Consumes: `RuleStore`、`RuleLibrary`、`Rule`。
- Produces:
  - `@MainActor @Observable final class RuleListModel` — `init(store: RuleStore)`；`private(set) var rules: [Rule]`；`var errorMessage: String?`。
  - `func reload() async` — 从 store 载入 `rules`（失败置 `errorMessage`）。
  - `func setEnabled(_ enabled: Bool, ruleID: UUID) async` — 改某规则启停并持久化。
  - `func move(fromOffsets: IndexSet, toOffset: Int) async` — 重排（决定优先级）并持久化。
  - `func duplicate(ruleID: UUID) async` — 复制一条（新 UUID、name 加「副本」后缀），插在原规则之后，持久化。
  - `func delete(ruleID: UUID) async` — 删除并持久化。
  - `func add(_ rule: Rule) async` — 追加新规则并持久化（供编辑器保存新规则用）。
  - `func update(_ rule: Rule) async` — 按 id 覆盖已有规则并持久化（供编辑器保存修改用）。
  - `func exportJSON(ruleID: UUID) -> String?` — 单条规则导出为格式化 JSON 字符串（供右键复制/导出）。
  - 内部 `save()` 持久化当前 `rules` 为 `RuleLibrary(version: .currentVersion, rules:)`。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/ViewModels/RuleListModelTests.swift`：

```swift
import XCTest
@testable import Sage

@MainActor
final class RuleListModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageRuleList-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func rule(_ name: String) -> Rule {
        Rule(id: UUID(), name: name, enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [], actions: [.addFinderTags([name])], executionMode: .automatic)
    }

    func test加载与启停持久化() async throws {
        let store = RuleStore(directory: dir)
        let r = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [r]))
        let model = RuleListModel(store: store)
        await model.reload()
        XCTAssertEqual(model.rules.map(\.name), ["A"])
        await model.setEnabled(false, ruleID: r.id)
        XCTAssertFalse(model.rules[0].enabled)
        let reloaded = try await store.load()
        XCTAssertFalse(reloaded.rules[0].enabled)
    }

    func test复制插在原规则之后() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A"); let b = rule("B")
        try await store.save(RuleLibrary(version: 1, rules: [a, b]))
        let model = RuleListModel(store: store)
        await model.reload()
        await model.duplicate(ruleID: a.id)
        XCTAssertEqual(model.rules.count, 3)
        XCTAssertEqual(model.rules[1].name, "A 副本")
        XCTAssertNotEqual(model.rules[1].id, a.id)
        XCTAssertEqual(model.rules[2].name, "B")
    }

    func test删除与新增() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [a]))
        let model = RuleListModel(store: store)
        await model.reload()
        await model.delete(ruleID: a.id)
        XCTAssertTrue(model.rules.isEmpty)
        await model.add(rule("New"))
        XCTAssertEqual(model.rules.map(\.name), ["New"])
        XCTAssertEqual(try await store.load().rules.map(\.name), ["New"])
    }

    func test导出JSON非空且可解码() async throws {
        let store = RuleStore(directory: dir)
        let a = rule("A")
        try await store.save(RuleLibrary(version: 1, rules: [a]))
        let model = RuleListModel(store: store)
        await model.reload()
        let json = model.exportJSON(ruleID: a.id)
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Rule.self, from: data)
        XCTAssertEqual(decoded.id, a.id)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'RuleListModel'`。

- [ ] **Step 3: 实现**

`Sources/Sage/ViewModels/RuleListModel.swift`：

```swift
import Foundation
import Observation

/// 规则库视图模型：加载、启停、重排、复制、增删、导出。
@MainActor
@Observable
public final class RuleListModel {
    public private(set) var rules: [Rule] = []
    public var errorMessage: String?

    private let store: RuleStore

    public init(store: RuleStore) { self.store = store }

    public func reload() async {
        do { rules = try await store.load().rules; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    public func setEnabled(_ enabled: Bool, ruleID: UUID) async {
        guard let idx = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[idx].enabled = enabled
        await save()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) async {
        rules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        await save()
    }

    public func duplicate(ruleID: UUID) async {
        guard let idx = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        var copy = rules[idx]
        copy.id = UUID()
        copy.name = "\(copy.name) 副本"
        rules.insert(copy, at: idx + 1)
        await save()
    }

    public func delete(ruleID: UUID) async {
        rules.removeAll { $0.id == ruleID }
        await save()
    }

    public func add(_ rule: Rule) async {
        rules.append(rule)
        await save()
    }

    public func update(_ rule: Rule) async {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        await save()
    }

    public func exportJSON(ruleID: UUID) -> String? {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rule) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save() async {
        do { try await store.save(RuleLibrary(version: RuleLibrary.currentVersion, rules: rules)); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter RuleListModelTests`
Expected: PASS（4 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/ViewModels/RuleListModel.swift Tests/SageTests/ViewModels/RuleListModelTests.swift
git commit -m "feat(sage): RuleListModel 规则库视图模型"
```

---

### Task 3: 规则编辑器视图模型（RuleEditorModel + 试运行）

**Files:**
- Create: `Sources/Sage/ViewModels/RuleEditorModel.swift`
- Test: `Tests/SageTests/ViewModels/RuleEditorModelTests.swift`

**Interfaces:**
- Consumes: `Rule`、`Condition`、`Action`、`RuleEngine`、`FileEvent`、`ActionPlan`、`FactsProvider`。
- Produces:
  - `struct DryRunResult: Sendable, Equatable` — `matched: Bool`、`ruleName: String`、`resolvedActions: [String]`（每个动作的人类可读描述，如「移动到 /out」「重命名为 {title}」）。试运行只跑 `RuleEngine.plan` 不执行。
  - `@MainActor @Observable final class RuleEditorModel` — `init(rule: Rule, engine: RuleEngine)`；`var draft: Rule`（可编辑草稿）；`var dryRun: DryRunResult?`；`var errorMessage: String?`。
  - `func addCondition(_ c: Condition)` / `func removeCondition(at: Int)` — 增删条件行（直接改 `draft.conditions`）。
  - `func addAction(_ a: Action)` / `func removeAction(at: Int)` — 增删动作行。
  - `func performDryRun(samplePath: String) async` — 以 `samplePath` 造一个 `.manual` `FileEvent`，用 `engine.plan(for:rules:[draft])` 求值，把结果写入 `dryRun`（matched=planned 非空；resolvedActions 由 `describe(action:)` 生成）。
  - `nonisolated static func describe(_ action: Action) -> String` — 动作 → 中文描述（供试运行与列表复用）。
  - `var isValid: Bool` — 校验：name 非空且 actions 非空（编辑器保存按钮的启用条件）。

**语义要点：** 含 LLM 动作的新规则的 `executionMode` 默认应为 `.confirmFirst`（spec §7.5）——该默认在编辑器「新建」入口设置（见 Task 8 的 View 层），本 ViewModel 不强制改写用户已选模式，只提供 `isValid` 与试运行。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/ViewModels/RuleEditorModelTests.swift`：

```swift
import XCTest
@testable import Sage

@MainActor
final class RuleEditorModelTests: XCTestCase {
    private func engine(ext: String) -> RuleEngine {
        RuleEngine(provider: FakeFactsProvider(cheap: CheapFacts(name: "a", fileExtension: ext, sizeBytes: 10)))
    }

    private func baseRule() -> Rule {
        Rule(id: UUID(), name: "R", enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
             actions: [.moveTo(path: "/out")], executionMode: .automatic)
    }

    func test试运行匹配() async {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        await model.performDryRun(samplePath: "/in/a.pdf")
        XCTAssertEqual(model.dryRun?.matched, true)
        XCTAssertEqual(model.dryRun?.resolvedActions.first, "移动到 /out")
    }

    func test试运行不匹配() async {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "jpg"))
        await model.performDryRun(samplePath: "/in/a.jpg")
        XCTAssertEqual(model.dryRun?.matched, false)
    }

    func test增删条件与动作() {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        model.addAction(.addFinderTags(["x"]))
        XCTAssertEqual(model.draft.actions.count, 2)
        model.removeAction(at: 0)
        XCTAssertEqual(model.draft.actions.count, 1)
        model.addCondition(.name(.contains("发票")))
        XCTAssertEqual(model.draft.conditions.count, 2)
        model.removeCondition(at: 1)
        XCTAssertEqual(model.draft.conditions.count, 1)
    }

    func test校验() {
        let model = RuleEditorModel(rule: baseRule(), engine: engine(ext: "pdf"))
        XCTAssertTrue(model.isValid)
        model.draft.name = ""
        XCTAssertFalse(model.isValid)
        model.draft.name = "R"
        model.draft.actions = []
        XCTAssertFalse(model.isValid)
    }

    func test动作描述() {
        XCTAssertEqual(RuleEditorModel.describe(.rename(template: "{title}")), "重命名为 {title}")
        XCTAssertEqual(RuleEditorModel.describe(.moveToTrash), "移到废纸篓")
        XCTAssertEqual(RuleEditorModel.describe(.llmExtractMetadata), "用 LLM 提取元数据")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'RuleEditorModel'`。

- [ ] **Step 3: 实现**

`Sources/Sage/ViewModels/RuleEditorModel.swift`：

```swift
import Foundation
import Observation

/// 试运行结果：仅匹配预览，不执行。
public struct DryRunResult: Sendable, Equatable {
    public var matched: Bool
    public var ruleName: String
    public var resolvedActions: [String]
    public init(matched: Bool, ruleName: String, resolvedActions: [String]) {
        self.matched = matched; self.ruleName = ruleName; self.resolvedActions = resolvedActions
    }
}

/// 规则编辑器视图模型：编辑草稿 + 试运行预览。
@MainActor
@Observable
public final class RuleEditorModel {
    public var draft: Rule
    public var dryRun: DryRunResult?
    public var errorMessage: String?

    private let engine: RuleEngine

    public init(rule: Rule, engine: RuleEngine) {
        self.draft = rule
        self.engine = engine
    }

    public var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.actions.isEmpty
    }

    public func addCondition(_ c: Condition) { draft.conditions.append(c) }
    public func removeCondition(at index: Int) {
        guard draft.conditions.indices.contains(index) else { return }
        draft.conditions.remove(at: index)
    }
    public func addAction(_ a: Action) { draft.actions.append(a) }
    public func removeAction(at index: Int) {
        guard draft.actions.indices.contains(index) else { return }
        draft.actions.remove(at: index)
    }

    public func performDryRun(samplePath: String) async {
        let event = FileEvent(location: .local(path: samplePath), source: .manual)
        let plan = await engine.plan(for: event, rules: [draft])
        if let matched = plan.planned.first {
            dryRun = DryRunResult(matched: true, ruleName: matched.ruleName,
                                  resolvedActions: matched.actions.map { Self.describe($0) })
        } else {
            dryRun = DryRunResult(matched: false, ruleName: draft.name, resolvedActions: [])
        }
    }

    /// 动作 → 中文描述。
    public nonisolated static func describe(_ action: Action) -> String {
        switch action {
        case .moveTo(let path): return "移动到 \(path)"
        case .copyTo(let path): return "复制到 \(path)"
        case .rename(let template): return "重命名为 \(template)"
        case .addFinderTags(let tags): return "加 Finder 标签 \(tags.joined(separator: "、"))"
        case .moveToTrash: return "移到废纸篓"
        case .dtImport(let db, let group, _, _): return "导入 DEVONthink：\(db)\(group)"
        case .dtRename(let template): return "DEVONthink 内重命名为 \(template)"
        case .dtAddTags(let tags): return "DEVONthink 加标签 \(tags.joined(separator: "、"))"
        case .dtMoveToGroup(let db, let group): return "DEVONthink 移动到 \(db)\(group)"
        case .llmExtractMetadata: return "用 LLM 提取元数据"
        case .llmRename(let instruction): return "用 LLM 命名（\(instruction)）"
        case .continueMatching: return "继续匹配后续规则"
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter RuleEditorModelTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/ViewModels/RuleEditorModel.swift Tests/SageTests/ViewModels/RuleEditorModelTests.swift
git commit -m "feat(sage): RuleEditorModel 规则编辑器视图模型与试运行"
```

---

### Task 4: 确认队列视图模型（ConfirmQueueModel）

**Files:**
- Create: `Sources/Sage/ViewModels/ConfirmQueueModel.swift`
- Test: `Tests/SageTests/ViewModels/ConfirmQueueModelTests.swift`

**Interfaces:**
- Consumes: `ConfirmQueue`、`Coordinator`、`PendingItem`、`ActionOutcome`。
- Produces:
  - `@MainActor @Observable final class ConfirmQueueModel` — `init(queue: ConfirmQueue, coordinator: Coordinator)`；`private(set) var items: [PendingItem]`；`var errorMessage: String?`。
  - `func reload() async` — 从 queue 载入 `items`。
  - `func approve(id: UUID) async` — 调 `coordinator.approve(pendingID:)`，成功后 `reload()`；`.failed` 时置 `errorMessage`。
  - `func reject(id: UUID) async` — 调 `coordinator.reject(pendingID:)`，`reload()`。
  - `func approveAll() async` / `func rejectAll() async` — 批量（顺序处理当前 items 快照）。
  - `nonisolated static func summary(_ item: PendingItem) -> String` — 「源 → 动作序列」一行摘要（复用 `RuleEditorModel.describe`）。

**语义要点：** 本 ViewModel 暂不实现「单条编辑目标路径后批准」——那是 View 层的目标编辑（spec §6），可在 Task 8 的 View 里对 item 的动作参数就地改后再调 approve；本迭代 approve 用原 planned 执行。编辑目标能力列入 Task 8 手动清单，若时间允许再加 `approve(id:overridingActions:)` 重载（不在本 ViewModel 的最小实现里）。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/ViewModels/ConfirmQueueModelTests.swift`：

```swift
import XCTest
@testable import Sage

@MainActor
final class ConfirmQueueModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageQueueVM-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // 组装一个真实 Coordinator（确认规则：pdf → 移到废纸篓）
    private func makeStack(rulePath: String) async throws -> (ConfirmQueueModel, Coordinator, ConfirmQueue) {
        let engine = RuleEngine(provider: FakeFactsProvider(cheap: CheapFacts(name: "a", fileExtension: "pdf", sizeBytes: 1)))
        let rule = Rule(id: UUID(), name: "删除", enabled: true,
                        scopes: [.localFolder(path: dir.path, recursive: true)], trigger: .automatic,
                        conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
                        actions: [.moveToTrash], executionMode: .confirmFirst)
        let store = RuleStore(directory: dir)
        try await store.save(RuleLibrary(version: 1, rules: [rule]))
        let queue = ConfirmQueue(directory: dir)
        let coordinator = Coordinator(
            engine: engine, rulesProvider: RuleStoreRulesProvider(store: store),
            executor: LocalActionExecutor(metadataProvider: FakeMetadataProvider(result: .init())),
            journal: Journal(directory: dir), confirmQueue: queue)
        return (ConfirmQueueModel(queue: queue, coordinator: coordinator), coordinator, queue)
    }

    func test加载与批准出队执行() async throws {
        let src = try makeFile("a.pdf")
        let (model, coordinator, queue) = try await makeStack(rulePath: src)
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        XCTAssertEqual(model.items.count, 1)
        let id = model.items[0].id
        await model.approve(id: id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src)) // 已删
        XCTAssertEqual(try await queue.count(), 0)
    }

    func test拒绝出队不执行() async throws {
        let src = try makeFile("b.pdf")
        let (model, coordinator, _) = try await makeStack(rulePath: src)
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        await model.reject(id: model.items[0].id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src)) // 未删
    }

    func test摘要非空() async throws {
        let src = try makeFile("c.pdf")
        let (model, coordinator, _) = try await makeStack(rulePath: src)
        _ = await coordinator.handle(FileEvent(location: .local(path: src), source: .manual))
        await model.reload()
        let s = ConfirmQueueModel.summary(model.items[0])
        XCTAssertTrue(s.contains("废纸篓"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'ConfirmQueueModel'`。

- [ ] **Step 3: 实现**

`Sources/Sage/ViewModels/ConfirmQueueModel.swift`：

```swift
import Foundation
import Observation

/// 确认队列视图模型：列出待确认项，批准/拒绝（含批量）。
@MainActor
@Observable
public final class ConfirmQueueModel {
    public private(set) var items: [PendingItem] = []
    public var errorMessage: String?

    private let queue: ConfirmQueue
    private let coordinator: Coordinator

    public init(queue: ConfirmQueue, coordinator: Coordinator) {
        self.queue = queue; self.coordinator = coordinator
    }

    public func reload() async {
        do { items = try await queue.all(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    public func approve(id: UUID) async {
        let outcome = await coordinator.approve(pendingID: id)
        if case .failed(_, _, let message) = outcome { errorMessage = message }
        await reload()
    }

    public func reject(id: UUID) async {
        do { try await coordinator.reject(pendingID: id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        await reload()
    }

    public func approveAll() async {
        for item in items { _ = await coordinator.approve(pendingID: item.id) }
        await reload()
    }

    public func rejectAll() async {
        for item in items { try? await coordinator.reject(pendingID: item.id) }
        await reload()
    }

    /// 「源 → 动作序列」一行摘要。
    public nonisolated static func summary(_ item: PendingItem) -> String {
        let source: String
        switch item.event.location {
        case .local(let path): source = (path as NSString).lastPathComponent
        case .devonthink(_, let db, let group): source = "\(db)\(group)"
        }
        let actions = item.planned.actions.map { RuleEditorModel.describe($0) }.joined(separator: " → ")
        return "\(source)：\(actions)"
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ConfirmQueueModelTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/ViewModels/ConfirmQueueModel.swift Tests/SageTests/ViewModels/ConfirmQueueModelTests.swift
git commit -m "feat(sage): ConfirmQueueModel 确认队列视图模型"
```

---

### Task 5: 日志视图模型（JournalModel）

**Files:**
- Create: `Sources/Sage/ViewModels/JournalModel.swift`
- Test: `Tests/SageTests/ViewModels/JournalModelTests.swift`

**Interfaces:**
- Consumes: `Journal`、`JournalRecord`、`ReversibleOp`。
- Produces:
  - `@MainActor @Observable final class JournalModel` — `init(journal: Journal)`；`private(set) var records: [JournalRecord]`；`var errorMessage: String?`。
  - `func reload() async` — 载入 `records`（Journal.all 已按时间倒序）。
  - `func rollback(id: UUID) async` — 调 `journal.rollback(id:)`，成功 `reload()`，失败置 `errorMessage`。
  - `nonisolated static func summary(_ record: JournalRecord) -> String` — 「规则名 · 操作数 · 源」一行摘要。
  - `nonisolated static func describe(_ op: ReversibleOp) -> String` — 单个可逆操作的中文描述。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/ViewModels/JournalModelTests.swift`：

```swift
import XCTest
@testable import Sage

@MainActor
final class JournalModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageJournalVM-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test加载与回滚() async throws {
        // 造一个真实 move 记录并回滚
        let src = dir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let dst = dir.appendingPathComponent("moved.pdf")
        try FileManager.default.moveItem(at: src, to: dst)
        let journal = Journal(directory: dir)
        let record = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                   sourceDescription: src.path, ops: [.moved(from: src.path, to: dst.path)])
        try await journal.append(record)
        let model = JournalModel(journal: journal)
        await model.reload()
        XCTAssertEqual(model.records.count, 1)
        await model.rollback(id: record.id)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path)) // 已移回
    }

    func test摘要与操作描述() {
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "发票归档",
                                sourceDescription: "/in/a.pdf", ops: [.moved(from: "/in/a.pdf", to: "/out/a.pdf")])
        XCTAssertTrue(JournalModel.summary(rec).contains("发票归档"))
        XCTAssertEqual(JournalModel.describe(.moved(from: "/a", to: "/b")), "移动 /a → /b")
        XCTAssertEqual(JournalModel.describe(.trashed(originalPath: "/a", trashPath: nil)), "移到废纸篓 /a")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'JournalModel'`。

- [ ] **Step 3: 实现**

`Sources/Sage/ViewModels/JournalModel.swift`：

```swift
import Foundation
import Observation

/// 日志视图模型：列出操作记录，逐条回滚。
@MainActor
@Observable
public final class JournalModel {
    public private(set) var records: [JournalRecord] = []
    public var errorMessage: String?

    private let journal: Journal

    public init(journal: Journal) { self.journal = journal }

    public func reload() async {
        do { records = try await journal.all(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    public func rollback(id: UUID) async {
        do { try await journal.rollback(id: id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        await reload()
    }

    public nonisolated static func summary(_ record: JournalRecord) -> String {
        "\(record.ruleName) · \(record.ops.count) 步 · \(record.sourceDescription)"
    }

    public nonisolated static func describe(_ op: ReversibleOp) -> String {
        switch op {
        case .moved(let from, let to): return "移动 \(from) → \(to)"
        case .copied(let to): return "复制到 \(to)"
        case .renamed(let from, let to): return "重命名 \(from) → \(to)"
        case .trashed(let originalPath, _): return "移到废纸篓 \(originalPath)"
        case .addedFinderTags(let tags, let path, _): return "加标签 \(tags.joined(separator: "、")) 于 \(path)"
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter JournalModelTests`
Expected: PASS（2 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/ViewModels/JournalModel.swift Tests/SageTests/ViewModels/JournalModelTests.swift
git commit -m "feat(sage): JournalModel 日志视图模型"
```

---

### Task 6: 监控总管（WatcherSupervisor）

**Files:**
- Create: `Sources/Sage/Watchers/WatcherSupervisor.swift`
- Test: `Tests/SageTests/Watchers/WatcherSupervisorTests.swift`

**Interfaces:**
- Consumes: `Rule`、`RuleScope`、`FolderWatcher`、`Coordinator`、`FileEvent`。
- Produces:
  - `nonisolated static func watchedRoots(rules: [Rule]) -> [WatchedRoot]`（纯函数，可测）——从启用且 `trigger == .automatic` 的规则的 `.localFolder` 作用域收集去重的监控根：`struct WatchedRoot: Sendable, Equatable, Hashable { let path: String; let recursive: Bool }`（同 path 若有 recursive 与非 recursive，取 recursive=true 合并）。
  - `actor WatcherSupervisor` — `init(coordinator: Coordinator)`；`func start(rules: [Rule]) async`（按 `watchedRoots` 建 `FolderWatcher` 并 `start()`，事件回调 `await coordinator.handle(_)`）；`func stopAll() async`（停所有 watcher）；`func restart(rules: [Rule]) async`（stopAll 后按新规则 start——供规则变更或监控开关切换时调用）。
  - FSEvents 实际接线不做自动化测试；本任务的自动化测试只覆盖 `watchedRoots` 纯逻辑。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Watchers/WatcherSupervisorTests.swift`：

```swift
import XCTest
@testable import Sage

final class WatcherSupervisorTests: XCTestCase {
    private func rule(name: String, enabled: Bool, trigger: TriggerMode, scopes: [RuleScope]) -> Rule {
        Rule(id: UUID(), name: name, enabled: enabled, scopes: scopes, trigger: trigger,
             conditionLogic: .all, conditions: [], actions: [.addFinderTags(["x"])], executionMode: .automatic)
    }

    func test收集去重监控根() {
        let rules = [
            rule(name: "A", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/in", recursive: false)]),
            rule(name: "B", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/in", recursive: true)]),
            rule(name: "C", enabled: true, trigger: .automatic, scopes: [.localFolder(path: "/other", recursive: false)]),
        ]
        let roots = WatcherSupervisor.watchedRoots(rules: rules)
        // /in 合并为 recursive=true；/other 保持 false
        XCTAssertEqual(Set(roots), Set([
            WatchedRoot(path: "/in", recursive: true),
            WatchedRoot(path: "/other", recursive: false),
        ]))
    }

    func test跳过禁用与仅手动规则() {
        let rules = [
            rule(name: "disabled", enabled: false, trigger: .automatic, scopes: [.localFolder(path: "/a", recursive: true)]),
            rule(name: "manual", enabled: true, trigger: .manualOnly, scopes: [.localFolder(path: "/b", recursive: true)]),
            rule(name: "dtonly", enabled: true, trigger: .automatic, scopes: [.devonthink(database: "D", groupPath: "/G")]),
        ]
        XCTAssertTrue(WatcherSupervisor.watchedRoots(rules: rules).isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'WatcherSupervisor'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Watchers/WatcherSupervisor.swift`：

```swift
import Foundation

/// 需监控的本地根目录。
public struct WatchedRoot: Sendable, Equatable, Hashable {
    public let path: String
    public let recursive: Bool
    public init(path: String, recursive: Bool) { self.path = path; self.recursive = recursive }
}

/// 监控总管：按当前规则集启停 FolderWatcher，事件转交 Coordinator。
public actor WatcherSupervisor {
    private let coordinator: Coordinator
    private var watchers: [FolderWatcher] = []

    public init(coordinator: Coordinator) { self.coordinator = coordinator }

    /// 从启用的自动规则收集去重监控根（同 path 有递归则合并为递归）。
    public nonisolated static func watchedRoots(rules: [Rule]) -> [WatchedRoot] {
        var map: [String: Bool] = [:] // path -> recursive
        for rule in rules where rule.enabled && rule.trigger == .automatic {
            for scope in rule.scopes {
                if case .localFolder(let path, let recursive) = scope {
                    map[path] = (map[path] ?? false) || recursive
                }
            }
        }
        return map.map { WatchedRoot(path: $0.key, recursive: $0.value) }
    }

    public func start(rules: [Rule]) async {
        let roots = Self.watchedRoots(rules: rules)
        let coordinator = self.coordinator
        for root in roots {
            let watcher = FolderWatcher(roots: [root.path], recursive: root.recursive) { event in
                _ = await coordinator.handle(event)
            }
            watcher.start()
            watchers.append(watcher)
        }
    }

    public func stopAll() async {
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
    }

    public func restart(rules: [Rule]) async {
        await stopAll()
        await start(rules: rules)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter WatcherSupervisorTests`
Expected: PASS（2 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Watchers/WatcherSupervisor.swift Tests/SageTests/Watchers/WatcherSupervisorTests.swift
git commit -m "feat(sage): WatcherSupervisor 监控总管"
```

---

### Task 7: 应用装配根（AppModel）

**Files:**
- Create: `Sources/Sage/ViewModels/AppModel.swift`
- Test: `Tests/SageTests/ViewModels/AppModelTests.swift`

**Interfaces:**
- Consumes: 全部 store/actor/ViewModel + `SageCore`、`SettingsStore`、`SageKeychainStore`、`WatcherSupervisor`、`LLMGateway`/`HTTPLLMProvider`。
- Produces:
  - `@MainActor @Observable final class AppModel` — 顶层协调：持有并暴露子 ViewModel（`ruleList`、`confirmQueue`、`journal`）、`settings: SageSettings`、`pendingCount: Int`、`recentActivity: [ActivityEntry]`、`errorMessage`。
    - `struct ActivityEntry: Identifiable, Sendable, Equatable { let id: UUID; let timestamp: Date; let text: String }`
  - `init(supportDirectory: URL, keychain: SageKeychainStore = .init())` — 载入 settings（同步用 `SettingsStore` 需 await，故提供 `static func bootstrap(supportDirectory:) async -> AppModel` 工厂完成异步装配；`init` 保留一个用于测试的、注入好依赖的形态）。为可测，提供：
    - `init(supportDirectory: URL, settings: SageSettings, gateway: LLMGateway, keychain: SageKeychainStore)` — 直接注入，装配 SageCore + 子 ViewModel + WatcherSupervisor。
    - `static func bootstrap(supportDirectory: URL) async -> AppModel` — 读 settings、从 Keychain 取 key、构造 gateway，调用上面的 init。
  - `func refreshQueueBadge() async` — 刷新 `pendingCount = confirmQueue.count`。
  - `func handleManualDrop(paths: [String]) async` — `manualIntake.events` → 逐个 `coordinator.handle`，把 outcomes 转 `recentActivity`（保留最近 10 条），刷新 badge。
  - `func setMonitoring(_ on: Bool) async` — 改 settings.monitoringEnabled、持久化、`supervisor.restart` 或 `stopAll`。
  - `func applySettings(_ new: SageSettings, apiKey: String?) async` — 保存 settings（apiKey 非 nil 时写 Keychain）、重建 gateway 相关（本迭代允许重启后生效，记录到 errorMessage 提示）。
  - `nonisolated static func activityText(for outcome: ActionOutcome) -> String` — outcome → 一行活动文本。

**语义要点：** 测试聚焦可确定性的部分：`handleManualDrop` 后 `recentActivity` 与 `pendingCount` 正确；`activityText` 映射；`setMonitoring(false)` 落盘。真实 FSEvents/网络不在测试内。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/ViewModels/AppModelTests.swift`：

```swift
import XCTest
@testable import Sage

@MainActor
final class AppModelTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SageApp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> AppModel {
        let gateway = LLMGateway(provider: FakeLLMProvider(content: "{}"))
        return AppModel(supportDirectory: dir, settings: .defaults, gateway: gateway, keychain: SageKeychainStore())
    }

    func test手动拖入触发自动规则并进活动() async throws {
        // 规则：pdf → 移动到 out
        let inDir = dir.appendingPathComponent("in"); let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = inDir.appendingPathComponent("a.pdf")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let store = RuleStore(directory: dir)
        try await store.save(RuleLibrary(version: 1, rules: [
            Rule(id: UUID(), name: "移动", enabled: true, scopes: [.localFolder(path: inDir.path, recursive: true)],
                 trigger: .automatic, conditionLogic: .all, conditions: [.fileExtension(.equals("pdf"))],
                 actions: [.moveTo(path: outDir.path)], executionMode: .automatic)]))

        let model = makeModel()
        await model.handleManualDrop(paths: [src.path])
        XCTAssertFalse(model.recentActivity.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("a.pdf").path))
    }

    func test监控开关落盘() async throws {
        let model = makeModel()
        await model.setMonitoring(false)
        XCTAssertFalse(model.settings.monitoringEnabled)
        let reloaded = try await SettingsStore(directory: dir).load()
        XCTAssertFalse(reloaded.monitoringEnabled)
    }

    func test活动文本映射() {
        let rec = JournalRecord(id: UUID(), timestamp: Date(), ruleID: UUID(), ruleName: "R",
                                sourceDescription: "/a.pdf", ops: [])
        XCTAssertTrue(AppModel.activityText(for: .executed(rec)).contains("R"))
        XCTAssertTrue(AppModel.activityText(for: .skipped(reason: "无匹配规则")).contains("无匹配"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build --build-tests`
Expected: FAIL，`cannot find 'AppModel'`。

- [ ] **Step 3: 实现**

`Sources/Sage/ViewModels/AppModel.swift`：

```swift
import Foundation
import Observation

/// 顶层应用模型：装配 SageCore 与子 ViewModel，承载全局状态。
@MainActor
@Observable
public final class AppModel {
    public struct ActivityEntry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let text: String
        public init(id: UUID = UUID(), timestamp: Date = Date(), text: String) {
            self.id = id; self.timestamp = timestamp; self.text = text
        }
    }

    public var settings: SageSettings
    public private(set) var pendingCount: Int = 0
    public private(set) var recentActivity: [ActivityEntry] = []
    public var errorMessage: String?

    public let ruleList: RuleListModel
    public let confirmQueue: ConfirmQueueModel
    public let journal: JournalModel

    private let coordinator: Coordinator
    private let manualIntake: ManualIntake
    private let queue: ConfirmQueue
    private let settingsStore: SettingsStore
    private let keychain: SageKeychainStore
    private let supervisor: WatcherSupervisor

    public init(supportDirectory: URL, settings: SageSettings, gateway: LLMGateway,
                keychain: SageKeychainStore) {
        self.settings = settings
        self.keychain = keychain
        self.settingsStore = SettingsStore(directory: supportDirectory)

        let assembled = SageCore.makeDefault(supportDirectory: supportDirectory, gateway: gateway)
        self.coordinator = assembled.coordinator
        self.manualIntake = assembled.manualIntake
        let store = RuleStore(directory: supportDirectory)
        self.queue = ConfirmQueue(directory: supportDirectory)
        let journalActor = Journal(directory: supportDirectory)

        self.ruleList = RuleListModel(store: store)
        self.confirmQueue = ConfirmQueueModel(queue: queue, coordinator: coordinator)
        self.journal = JournalModel(journal: journalActor)
        self.supervisor = WatcherSupervisor(coordinator: coordinator)
    }

    public static func bootstrap(supportDirectory: URL) async -> AppModel {
        let settingsStore = SettingsStore(directory: supportDirectory)
        let settings = (try? await settingsStore.load()) ?? .defaults
        let keychain = SageKeychainStore()
        let apiKey = (try? keychain.read(account: "llm-api-key")) ?? nil
        let gateway = Self.makeGateway(settings: settings, apiKey: apiKey ?? "")
        return AppModel(supportDirectory: supportDirectory, settings: settings, gateway: gateway, keychain: keychain)
    }

    private static func makeGateway(settings: SageSettings, apiKey: String) -> LLMGateway {
        let config = LLMGatewayConfig(budget: LLMBudget(dailyLimit: settings.dailyLLMBudget, date: Date()))
        if settings.provider.enabled, let url = URL(string: settings.provider.baseURL), !apiKey.isEmpty {
            let provider = HTTPLLMProvider(config: HTTPLLMConfig(
                baseURL: url, apiKey: apiKey, model: settings.provider.model,
                timeout: settings.provider.timeoutSeconds))
            return LLMGateway(provider: provider, config: config)
        }
        // 未配置时用一个永远失败降级的占位 provider（引擎会把 LLM 条件视为不匹配）
        return LLMGateway(provider: DisabledLLMProvider(), config: config)
    }

    public func refreshQueueBadge() async {
        pendingCount = (try? await queue.count()) ?? 0
    }

    public func handleManualDrop(paths: [String]) async {
        let events = manualIntake.events(forDroppedPaths: paths)
        for event in events {
            let outcomes = await coordinator.handle(event)
            for outcome in outcomes { pushActivity(Self.activityText(for: outcome)) }
        }
        await refreshQueueBadge()
        await confirmQueue.reload()
        await journal.reload()
    }

    public func setMonitoring(_ on: Bool) async {
        settings.monitoringEnabled = on
        await persistSettings()
        let rules = await ruleList.currentRulesSnapshot()
        if on { await supervisor.restart(rules: rules) } else { await supervisor.stopAll() }
    }

    public func applySettings(_ new: SageSettings, apiKey: String?) async {
        settings = new
        if let apiKey { try? keychain.write(account: "llm-api-key", value: apiKey) }
        await persistSettings()
        errorMessage = "部分设置（LLM 端点/密钥）将在下次启动后完全生效。"
    }

    private func persistSettings() async {
        do { try await settingsStore.save(settings) } catch { errorMessage = error.localizedDescription }
    }

    private func pushActivity(_ text: String) {
        recentActivity.insert(ActivityEntry(text: text), at: 0)
        if recentActivity.count > 10 { recentActivity.removeLast(recentActivity.count - 10) }
    }

    public nonisolated static func activityText(for outcome: ActionOutcome) -> String {
        switch outcome {
        case .executed(let r): return "已执行「\(r.ruleName)」：\(r.sourceDescription)"
        case .enqueued(let item): return "待确认：\(ConfirmQueueModel.summary(item))"
        case .failed(_, let ruleName, let message): return "失败「\(ruleName)」：\(message)"
        case .skipped(let reason): return "跳过：\(reason)"
        }
    }
}

/// 未配置 LLM 时的占位 provider：任何调用都抛错，触发引擎降级。
struct DisabledLLMProvider: LLMProvider {
    func send(_ request: LLMRequest) async throws -> LLMResponse {
        throw LLMGatewayError.parseFailed("未配置 LLM 服务")
    }
}
```

**实现说明：** `RuleListModel` 需要一个 `currentRulesSnapshot()`——为避免在 AppModel 里重复读 store，给 `RuleListModel` 加一个 `@MainActor func currentRulesSnapshot() async -> [Rule] { rules }`（若 `reload` 未调用过则先 `await reload()`）。在本任务中一并给 `RuleListModel` 补这个方法（修改 Task 2 产物），并在 Task 2 的测试不受影响。`LLMResponse` / `LLMProvider.send` / `LLMGatewayError` 的确切签名以现有 `Sources/Sage/LLM/LLMProvider.swift` 为准——实现前先读该文件，`DisabledLLMProvider` 按实际协议要求实现。

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter AppModelTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: 全量回归并提交**

Run: `swift test --filter SageTests`
Expected: 全绿（Plans 1–3 的 119 项 + 本计划 ViewModel 层新增）。

```bash
git add Sources/Sage/ViewModels Tests/SageTests/ViewModels
git commit -m "feat(sage): AppModel 顶层应用模型与装配"
```

---

### Task 8: SwiftUI 主窗口与各视图（构建 + 手动验证）

**Files:**
- Create: `Sources/Sage/Views/ContentView.swift`
- Create: `Sources/Sage/Views/RuleListView.swift`
- Create: `Sources/Sage/Views/RuleEditorView.swift`
- Create: `Sources/Sage/Views/ConfirmQueueView.swift`
- Create: `Sources/Sage/Views/JournalView.swift`
- Create: `Sources/Sage/Views/SettingsView.swift`

**门槛：** 本任务无自动化测试（SwiftUI 视图，spec §9 手动验证）。完成门槛为 `swift build` 通过；报告须附手动验证清单。

**Interfaces:** 消费 Task 2–7 的 ViewModel。`ContentView` 用 `NavigationSplitView`，侧栏枚举 `enum SidebarItem: Hashable { case rules, queue, journal }`（监控源总览并入 rules 页顶部条，简化）。所有视图接收 `AppModel` 作为 `@Bindable`/`@Environment` 传入。

- [ ] **Step 1: 实现 ContentView（侧栏 + 详情路由）**

`Sources/Sage/Views/ContentView.swift`：

```swift
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case rules = "规则"
    case queue = "待确认"
    case journal = "日志"
    var id: String { rawValue }
}

struct ContentView: View {
    @Bindable var app: AppModel
    @State private var selection: SidebarItem? = .rules

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                HStack {
                    Text(item.rawValue)
                    if item == .queue, app.pendingCount > 0 {
                        Spacer()
                        Text("\(app.pendingCount)")
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red)).foregroundStyle(.white)
                    }
                }.tag(Optional(item))
            }
            .navigationTitle("Sage")
            .frame(minWidth: 180)
        } detail: {
            switch selection ?? .rules {
            case .rules: RuleListView(app: app)
            case .queue: ConfirmQueueView(model: app.confirmQueue)
            case .journal: JournalView(model: app.journal)
            }
        }
        .task { await app.ruleList.reload(); await app.confirmQueue.reload()
                await app.journal.reload(); await app.refreshQueueBadge() }
    }
}
```

- [ ] **Step 2: 实现 RuleListView（列表 + 启停 + 编辑器入口）**

`Sources/Sage/Views/RuleListView.swift`：

```swift
import SwiftUI

struct RuleListView: View {
    @Bindable var app: AppModel
    @State private var editing: Rule?
    @State private var showingEditor = false

    private var engineForDryRun: RuleEngine {
        // 试运行用一个不触发真实网络的引擎；LLM 条件在无 key 时降级为不匹配
        RuleEngine(provider: FakeishFactsProvider())
    }

    var body: some View {
        List {
            ForEach(app.ruleList.rules) { rule in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { newValue in Task { await app.ruleList.setEnabled(newValue, ruleID: rule.id) } }
                    )).labelsHidden()
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(rule.name).font(.headline)
                            if rule.usesLLM { Text("✦").foregroundStyle(.purple) }
                        }
                        Text(scopeSummary(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(rule.trigger == .automatic ? "自动" : "手动")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = rule; showingEditor = true }
                .contextMenu {
                    Button("复制") { Task { await app.ruleList.duplicate(ruleID: rule.id) } }
                    Button("导出 JSON") {
                        if let json = app.ruleList.exportJSON(ruleID: rule.id) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(json, forType: .string)
                        }
                    }
                    Divider()
                    Button("删除", role: .destructive) { Task { await app.ruleList.delete(ruleID: rule.id) } }
                }
            }
            .onMove { offsets, dest in Task { await app.ruleList.move(fromOffsets: offsets, toOffset: dest) } }
        }
        .navigationTitle("规则")
        .toolbar {
            ToolbarItem {
                Button {
                    editing = newRuleTemplate(); showingEditor = true
                } label: { Label("新建规则", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let rule = editing {
                RuleEditorView(model: RuleEditorModel(rule: rule, engine: engineForDryRun)) { saved in
                    Task {
                        if app.ruleList.rules.contains(where: { $0.id == saved.id }) {
                            await app.ruleList.update(saved)
                        } else {
                            await app.ruleList.add(saved)
                        }
                    }
                }
            }
        }
    }

    private func scopeSummary(_ rule: Rule) -> String {
        rule.scopes.map { scope in
            switch scope {
            case .localFolder(let path, _): return (path as NSString).lastPathComponent
            case .devonthink(let db, let group): return "DT:\(db)\(group)"
            case .manualOnly: return "仅手动"
            }
        }.joined(separator: "、")
    }

    private func newRuleTemplate() -> Rule {
        // 新规则默认「先入确认队列」更安全（spec §7.5 对含 LLM 尤其如此）
        Rule(id: UUID(), name: "新规则", enabled: true, scopes: [.manualOnly], trigger: .manualOnly,
             conditionLogic: .all, conditions: [], actions: [], executionMode: .confirmFirst)
    }
}

/// 试运行占位 FactsProvider：无网络，LLM 判定一律 false，提取为空。
/// 真实试运行会由 AppModel 注入配置好的引擎；此处仅保证 View 可独立预览与构建。
struct FakeishFactsProvider: FactsProvider {
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        guard case .local(let path) = location else { return CheapFacts(name: "", fileExtension: "", sizeBytes: 0) }
        let name = (path as NSString).lastPathComponent
        return CheapFacts(name: (name as NSString).deletingPathExtension,
                          fileExtension: (name as NSString).pathExtension.lowercased(), sizeBytes: 0)
    }
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts { ExtractedFacts() }
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict { SemanticVerdict(matches: false, confidence: 0) }
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict { SemanticVerdict(matches: false, confidence: 0) }
}
```

**说明：** `RuleEditorView` 的作用域/条件/动作编辑器为简化版：条件与动作用「类型选择 + 关键参数文本框」。完整的每类型参数控件可在后续迭代细化；本任务保证可新建/编辑名称、作用域（本地文件夹选择）、触发方式、执行模式、若干条件与动作，并能试运行。

- [ ] **Step 3: 实现 RuleEditorView（sheet：字段 + 条件/动作行 + 试运行）**

`Sources/Sage/Views/RuleEditorView.swift`：

```swift
import SwiftUI
import UniformTypeIdentifiers

struct RuleEditorView: View {
    @Bindable var model: RuleEditorModel
    var onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sampleForDryRun: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.draft.name.isEmpty ? "编辑规则" : model.draft.name).font(.title2).bold()

            Form {
                TextField("名称", text: $model.draft.name)
                Picker("触发", selection: $model.draft.trigger) {
                    Text("监控自动").tag(TriggerMode.automatic)
                    Text("仅手动").tag(TriggerMode.manualOnly)
                }
                Picker("执行", selection: $model.draft.executionMode) {
                    Text("自动执行").tag(ExecutionMode.automatic)
                    Text("先入确认队列").tag(ExecutionMode.confirmFirst)
                }
                Picker("条件逻辑", selection: $model.draft.conditionLogic) {
                    Text("全部满足").tag(ConditionLogic.all)
                    Text("任一满足").tag(ConditionLogic.any)
                }
            }
            .frame(height: 130)

            GroupBox("动作（按序执行）") {
                ForEach(Array(model.draft.actions.enumerated()), id: \.offset) { idx, action in
                    HStack {
                        Text(RuleEditorModel.describe(action))
                        Spacer()
                        Button(role: .destructive) { model.removeAction(at: idx) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("添加动作") {
                    Button("加 Finder 标签…") { model.addAction(.addFinderTags(["标签"])) }
                    Button("重命名（模板）") { model.addAction(.rename(template: "{title}")) }
                    Button("用 LLM 提取元数据 ✦") { model.addAction(.llmExtractMetadata) }
                    Button("移到废纸篓（需确认）") { model.addAction(.moveToTrash) }
                }
            }

            HStack {
                TextField("试运行样本文件路径", text: $sampleForDryRun)
                Button("试运行") { Task { await model.performDryRun(samplePath: sampleForDryRun) } }
                    .disabled(sampleForDryRun.isEmpty)
            }
            if let dry = model.dryRun {
                GroupBox(dry.matched ? "✅ 命中" : "⛔️ 未命中") {
                    ForEach(dry.resolvedActions, id: \.self) { Text($0).font(.caption) }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { onSave(model.draft); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 460)
    }
}
```

- [ ] **Step 4: 实现 ConfirmQueueView 与 JournalView**

`Sources/Sage/Views/ConfirmQueueView.swift`：

```swift
import SwiftUI

struct ConfirmQueueView: View {
    @Bindable var model: ConfirmQueueModel

    var body: some View {
        VStack {
            if model.items.isEmpty {
                ContentUnavailableView("没有待确认项", systemImage: "checkmark.circle")
            } else {
                List(model.items) { item in
                    HStack {
                        Text(ConfirmQueueModel.summary(item))
                        Spacer()
                        Button("批准") { Task { await model.approve(id: item.id) } }
                        Button("拒绝", role: .destructive) { Task { await model.reject(id: item.id) } }
                    }
                }
            }
        }
        .navigationTitle("待确认队列")
        .toolbar {
            ToolbarItemGroup {
                Button("全部批准") { Task { await model.approveAll() } }.disabled(model.items.isEmpty)
                Button("全部拒绝", role: .destructive) { Task { await model.rejectAll() } }.disabled(model.items.isEmpty)
            }
        }
        .task { await model.reload() }
    }
}
```

`Sources/Sage/Views/JournalView.swift`：

```swift
import SwiftUI

struct JournalView: View {
    @Bindable var model: JournalModel

    var body: some View {
        VStack {
            if model.records.isEmpty {
                ContentUnavailableView("暂无操作记录", systemImage: "clock")
            } else {
                List(model.records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(JournalModel.summary(record)).font(.subheadline)
                            Spacer()
                            Button("回滚") { Task { await model.rollback(id: record.id) } }
                        }
                        ForEach(Array(record.ops.enumerated()), id: \.offset) { _, op in
                            Text(JournalModel.describe(op)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("日志")
        .task { await model.reload() }
    }
}
```

- [ ] **Step 5: 实现 SettingsView**

`Sources/Sage/Views/SettingsView.swift`：

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var apiKey: String = ""
    @State private var draft: SageSettings = .defaults

    var body: some View {
        TabView {
            Form {
                Toggle("开机自动启动", isOn: $draft.launchAtLogin)
                Toggle("启用监控", isOn: $draft.monitoringEnabled)
            }.tabItem { Label("通用", systemImage: "gear") }.padding()

            Form {
                Toggle("启用 LLM 增强", isOn: $draft.provider.enabled)
                TextField("服务地址（baseURL）", text: $draft.provider.baseURL)
                TextField("模型", text: $draft.provider.model)
                SecureField("API Key（存 Keychain）", text: $apiKey)
                TextField("每日调用上限（留空=不限）", value: $draft.dailyLLMBudget, format: .number)
            }.tabItem { Label("AI", systemImage: "sparkles") }.padding()
        }
        .frame(width: 460, height: 260)
        .onAppear { draft = app.settings }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task { await app.applySettings(draft, apiKey: apiKey.isEmpty ? nil : apiKey) }
                }
            }
        }
    }
}
```

- [ ] **Step 6: 构建验证并提交**

Run: `swift build`
Expected: Build complete（无错误）。若 SwiftUI/AppKit API 在 macOS 14 有出入（如 `ContentUnavailableView` 需 macOS 14+，可用；`onMove` 在普通 List 需配合 `.toolbar` 的 EditButton 或直接支持拖拽——若编译报错，改用 `List{}.onMove` 且不依赖编辑模式，或降级为右键「上移/下移」），据实调整到构建通过，保持 ViewModel 调用不变。

在报告中附**手动验证清单**：①主窗口三页切换正常、待确认角标显示计数；②新建规则→加动作→试运行显示命中/未命中→保存后出现在列表；③规则行启停开关即时生效并持久化（重启应用后保持）；④拖拽重排规则顺序保持；⑤右键导出 JSON 写入剪贴板；⑥确认队列批准/拒绝/全部批准生效；⑦日志回滚把文件移回。

```bash
git add Sources/Sage/Views
git commit -m "feat(sage): SwiftUI 主窗口、规则列表/编辑器、确认队列、日志、设置视图"
```

---

### Task 9: 菜单栏常驻、拖放热区与 App 入口（构建 + 手动验证）

**Files:**
- Delete/Replace: `Sources/Sage/App/main.swift`（移除 top-level 入口，改用 `@main`）
- Create: `Sources/Sage/App/SageApp.swift`
- Create: `Sources/Sage/App/MenuBarView.swift`
- Create: `Sources/Sage/App/LaunchAtLogin.swift`

**门槛：** 无自动化测试；`swift build` 通过 + 手动验证清单。

**Interfaces:** `@main struct SageApp: App` 组合 `Window`（主窗口，内嵌 `ContentView`）、`MenuBarExtra`（菜单栏 Popover，内嵌 `MenuBarView`）、`Settings`（内嵌 `SettingsView`）。`AppModel` 用 `@State` 持有，异步 `bootstrap` 后注入。

**关键：** `Sources/Sage/App/main.swift` 目前是 top-level 语句入口；SwiftUI `@main` 不能与同 target 内名为 `main.swift` 的 top-level 代码共存。必须删除 `main.swift`（其功能并入 `SageApp`），新增 `SageApp.swift` 承载 `@main`。

- [ ] **Step 1: 登录启动封装**

`Sources/Sage/App/LaunchAtLogin.swift`：

```swift
import Foundation
import ServiceManagement

/// 登录启动开关封装（SMAppService，macOS 13+）。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 命令行/未签名环境下可能失败；不崩溃，仅忽略（GUI .app 内可用）
            NSLog("LaunchAtLogin 设置失败：\(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: 菜单栏视图（总开关 + 待确认数 + 最近活动 + 拖放热区）**

`Sources/Sage/App/MenuBarView.swift`：

```swift
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("启用监控", isOn: Binding(
                get: { app.settings.monitoringEnabled },
                set: { on in Task { await app.setMonitoring(on) } }
            ))
            Divider()
            HStack {
                Text("待确认")
                Spacer()
                Text("\(app.pendingCount)").bold()
            }
            Divider()
            Text("最近活动").font(.caption).foregroundStyle(.secondary)
            if app.recentActivity.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(app.recentActivity.prefix(10)) { entry in
                    Text(entry.text).font(.caption).lineLimit(1)
                }
            }
            Divider()
            dropZone
            Divider()
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                // 主 Window 通过 openWindow 由 SageApp 提供；此处激活应用
            }
            Button("退出 Sage") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
        .task { await app.refreshQueueBadge() }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .frame(height: 56)
            .overlay(Text("拖入文件套用「仅手动」规则").font(.caption).foregroundStyle(.secondary))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task {
                    var paths: [String] = []
                    for provider in providers {
                        if let url = try? await provider.loadItem(forURL: ()) { paths.append(url.path) }
                    }
                    if !paths.isEmpty { await app.handleManualDrop(paths: paths) }
                }
                return true
            }
    }
}

private extension NSItemProvider {
    /// 从拖放 provider 取文件 URL。
    func loadItem(forURL: Void) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            _ = self.loadObject(ofClass: URL.self) { url, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}
```

**说明：** 若 `NSItemProvider.loadObject(ofClass: URL.self)` 在编译期不可用（URL 需符合 `_ObjectiveCBridgeable`，实际可用），改用 `provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier)` 解析。实现以构建通过为准。

- [ ] **Step 3: App 入口（替换 main.swift）**

先删除 `Sources/Sage/App/main.swift`，再创建 `Sources/Sage/App/SageApp.swift`：

```swift
import SwiftUI

@main
struct SageApp: App {
    @State private var app: AppModel?

    private static var supportDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var body: some Scene {
        Window("Sage", id: "main") {
            Group {
                if let app { ContentView(app: app) }
                else { ProgressView("正在启动…").task { app = await AppModel.bootstrap(supportDirectory: Self.supportDirectory) } }
            }
            .frame(minWidth: 720, minHeight: 460)
        }

        MenuBarExtra("Sage", systemImage: "leaf") {
            if let app { MenuBarView(app: app) }
            else { Text("正在启动…").padding().task { app = await AppModel.bootstrap(supportDirectory: Self.supportDirectory) } }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let app { SettingsView(app: app) }
        }
    }
}
```

**说明：** `bootstrap` 可能被主窗口与菜单栏各触发一次；为避免双装配，可将 `app` 的赋值加 `if self.app == nil` 守卫（`@State` 在 `.task` 内读取需通过绑定；实现时用一个 `@State private var isBootstrapping` 或把 bootstrap 提到 `init`/`AppDelegate`）。最简做法：用 `NSApplicationDelegateAdaptor` 里的单例 AppModel。实现者可据构建情况选其一，保证只装配一次且两处共享同一 `AppModel`。推荐：

```swift
// 用 AppDelegate 持有单例，避免双装配
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let shared = AppDelegate()
    @MainActor var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in model = await AppModel.bootstrap(supportDirectory: SageApp.supportDirectory) }
    }
}
```
并在 `SageApp` 用 `@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate`，视图从 `delegate.model` 读取（配合一个 loading 态）。以构建通过与「单次装配、两处共享」为准。

- [ ] **Step 4: 构建验证并提交**

Run: `swift build`
Expected: Build complete。逐一解决 `@main`/`main.swift` 冲突、`MenuBarExtra`/`Window`/`Settings` scene 可用性（均 macOS 13+/14+ 可用）、拖放 API。构建通过后运行 `swift run Sage` 冒烟（GUI 出现菜单栏叶子图标与主窗口）。

Run: `swift test --filter SageTests`
Expected: 全绿（无回归；本任务不新增测试）。

在报告中附**手动验证清单**：①启动后菜单栏出现叶子图标，点开显示监控开关/待确认数/最近活动/拖放热区；②菜单栏监控开关切换后 settings.json 落盘；③向拖放热区拖入文件触发「仅手动」规则并进最近活动；④「打开主窗口」激活主窗口；⑤设置窗口（⌘,）改 LLM 配置与 API Key，Key 进 Keychain 不入 settings.json；⑥登录启动开关在已签名 .app 内注册成功（命令行环境可忽略失败日志）。

```bash
git add Sources/Sage/App
git rm Sources/Sage/App/main.swift 2>/dev/null || true
git commit -m "feat(sage): 菜单栏常驻、拖放热区与 @main App 入口"
```

---

## 自检记录（写计划者已核对）

- **spec §6 覆盖**：主窗口规则中心（Task 8 ContentView/RuleListView）、规则编辑器含试运行（Task 3 + Task 8 RuleEditorView）、确认队列按项批准/批量（Task 4 + Task 8）、日志逐条回滚（Task 5 + Task 8）、菜单栏 Popover 总开关/待确认数/最近活动/拖放热区（Task 9）。§7.5「含 LLM 新规则默认 confirmFirst」由 Task 8 新建模板落实。§10 持久化与 Keychain（Task 1、Task 7）。登录启动（Task 9）。
- **未覆盖（有意）**：DEVONthink 相关 UI 与动作执行（第 5 份计划）；规则编辑器的「每条件/动作全参数控件」为简化版，作用域的图形化文件夹选择、条件类型全下拉留待后续细化（列入 Task 8 手动清单与后续迭代）；监控源总览独立页并入规则页顶（简化）。
- **类型一致性**：`RuleListModel.currentRulesSnapshot()` 在 Task 7 补充说明中新增，供 AppModel 使用；`RuleEditorModel.describe` 被 ConfirmQueueModel/JournalView 复用；`AppModel.ActivityEntry`、`SidebarItem` 均本计划内定义。
- **需实现时以现有代码核对的点（已在任务内标注）**：`LLMProvider.send`/`LLMResponse`/`LLMGatewayError` 签名（Task 7 `DisabledLLMProvider`）；`NSItemProvider` 取 URL 的可用 API（Task 9）；`ContentUnavailableView`/`onMove`/`MenuBarExtra` 的 macOS 14 行为（Task 8/9，构建为准）。

## 后续计划衔接

- **第 5 份（DEVONthink 集成，最后一份）**：实现 `DTActionExecutor`（AppleScript，字符串转义防注入）替换 `UnimplementedDTActionExecutor`；`DTWatcher` 轮询 DT 组；DT 位置的 `FactsProvider`；DT 导入回滚；规则编辑器补 DT 作用域与 DT 动作的参数 UI；菜单栏在 DT 未运行时的提示。
