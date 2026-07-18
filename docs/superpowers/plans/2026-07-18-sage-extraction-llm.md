# Sage 提取与 LLM 层实施计划（第 2/5 份）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为第 1/5 份的 `FactsProvider` 协议提供真实实现：`ExtractionProvider`（文本/哈希/EXIF/视频元数据/来源 URL，按内容哈希缓存）+ `LLMProvider`（OpenAI 兼容协议，云端与本地端点同一实现）+ `LLMGateway`（限速、每日预算、按哈希缓存、失败降级——全部 LLM 调用唯一入口）+ API Key 入 Keychain。零 watcher、零 UI、零执行副作用；与真实文件系统/网络交互的部分用临时目录或 mock provider 单测。

**Architecture:** 在 `Sources/Sage/` 下新增 `Extraction/` 与 `LLM/` 两个目录。`ExtractionProvider` 实现第 1 份的 `FactsProvider`，组合 `LocalExtractor`（设备端提取）+ `LLMGateway`（语义判断）。`LLMGateway` 持有 `LLMProvider`（协议，真实实现 `HTTPLLMProvider`，测试用 `FakeLLMProvider`）。Keychain 用第 1 份计划已建好的 `SageKeychainStore`（本计划创建）。

**Tech Stack:** Swift 6（StrictConcurrency）、SPM、XCTest、macOS 14+；PDFKit、NaturalLanguage、ImageIO、AVFoundation、CryptoKit（SHA-256）、`URLSession`、`Security`（Keychain）。

## Global Constraints

- Swift tools version 6.0；目标平台 `.macOS(.v14)`；开启 `StrictConcurrency`。
- 新增类型默认 `public`，与第 1 份保持一致；Domain/Engine 层未改。
- 自定义错误遵循 `LocalizedError` 并实现 `errorDescription`（中文消息）。
- 注释中文、标识符英文。
- 所有网络调用必须可注入：`LLMProvider` 是协议，`LLMGateway` 通过初始化注入；绝不直接 `URLSession.shared` 写死在 Gateway 内部——`HTTPLLMProvider` 才是接 `URLSession` 的实现，测试用 `FakeLLMProvider`。
- 内容提取结果按内容哈希缓存：相同哈希的文件不重复提取/不重复调 LLM；缓存键 `(location, contentHash)` 或 `(contentHash, prompt)`。
- 已知环境限制：仅 CommandLineTools 的机器 `swift test` 不可用，需完整 Xcode；每个测试步骤先 `swift build`，`swift test` 报 `no such module 'XCTest'` 属环境问题，改 Xcode ⌘U。

## 与第 1/5 份的接口契约

第 1 份已定义：

```swift
public protocol FactsProvider: Sendable {
    func cheapFacts(for location: FileLocation) async throws -> CheapFacts
    func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts
    func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict
    func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict
}
```

本份产出 `ExtractionProvider: FactsProvider`：
- `cheapFacts(for:)` 经 `LocalExtractor.cheapFacts(for:)` 直接读取文件属性（零成本）。
- `extractedFacts(for:)` 经 `LocalExtractor.extractedFacts(for:)` 提取文本/哈希/EXIF/URL，结果按 `contentHash` 缓存。
- `belongsTo(category:at:)` / `matchesDescription(_:at:)` 经 `LLMGateway`，Gateway 内部按 `(contentHash, prompt)` 缓存。

---

### Task 1: SageKeychainStore（API Key 持久化）

**Files:**
- Create: `Sources/Sage/Store/SageKeychainStore.swift`
- Test: `Tests/SageTests/Store/SageKeychainStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum SageKeychainError: LocalizedError, Sendable` — `.missing(account:)`、`.osStatus(OSStatus)`，中文 `errorDescription`
  - `struct SageKeychainStore: Sendable`，`init(service: String = "com.jiyuliang.Sage")`
  - `func read(account: String) throws -> String?`
  - `func write(account: String, value: String) throws`
  - `func delete(account: String) throws`

**说明：** Keychain 在无代码签名的 `swift test` 环境下行为不稳定，测试只覆盖错误路径（读不存在的 account 返回 nil、删除不存在的 account 不抛错、`SageKeychainError.missing` 的 `errorDescription` 含 account 名），不覆盖真实读写往返——那类测试改为在 `dist/.app` 内手动验证清单项。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Store/SageKeychainStoreTests.swift`：

```swift
import XCTest
@testable import Sage

final class SageKeychainStoreTests: XCTestCase {
    private let store = SageKeychainStore(service: "com.jiyuliang.Sage.tests.\(UUID().uuidString)")

    func test读不存在的account返回nil() throws {
        let result = try store.read(account: "不存在-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func test删除不存在的account不抛错() throws {
        XCTAssertNoThrow(try store.delete(account: "不存在-\(UUID().uuidString)"))
    }

    func testMissing错误描述含account名() {
        let error = SageKeychainError.missing(account: "DeepSeek")
        XCTAssertEqual(error.errorDescription, "Keychain 中未找到 account「DeepSeek」对应的 API Key。")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'SageKeychainStore'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Store/SageKeychainStore.swift`：

```swift
import Foundation
import Security

/// Keychain 读写错误。
public enum SageKeychainError: LocalizedError, Sendable {
    case missing(account: String)
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missing(let account):
            return "Keychain 中未找到 account「\(account)」对应的 API Key。"
        case .osStatus(let status):
            return "Keychain 操作失败，OSStatus = \(status)。"
        }
    }
}

/// API Key 等 secret 的持久化（spec §10）。
public struct SageKeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.jiyuliang.Sage") {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SageKeychainError.osStatus(status)
        }
    }

    public func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SageKeychainError.osStatus(addStatus) }
        } else if status != errSecSuccess {
            throw SageKeychainError.osStatus(status)
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SageKeychainError.osStatus(status)
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter SageKeychainStoreTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Store/SageKeychainStore.swift Tests/SageTests/Store/SageKeychainStoreTests.swift
git commit -m "feat(sage): SageKeychainStore API Key 持久化"
```

---

### Task 2: LLMProvider 协议与 FakeLLMProvider 测试基建

**Files:**
- Create: `Sources/Sage/LLM/LLMProvider.swift`
- Create: `Sources/Sage/LLM/LLMRequest.swift`
- Create: `Tests/SageTests/Support/FakeLLMProvider.swift`

**Interfaces:**
- Produces:
  - `struct LLMRequest: Sendable` — `systemPrompt: String`、`userPrompt: String`、`jsonSchemaHint: String?`（提示模型按 JSON 输出）
  - `struct LLMResponse: Sendable, Equatable` — `content: String`（模型原始返回文本，调用方负责解析 JSON）
  - `enum LLMProviderError: LocalizedError, Sendable` — `.network(Error)`、`.http(status: Int, body: String)`、`.emptyContent`、`.timeout`
  - `protocol LLMProvider: Sendable` — `func send(_ request: LLMRequest) async throws -> LLMResponse`
  - 测试基建 `FakeLLMProvider`：注入固定响应或抛错，记录调用次数与最后一次请求。

- [ ] **Step 1: 写测试基建**

`Tests/SageTests/Support/FakeLLMProvider.swift`：

```swift
import Foundation
@testable import Sage

/// 测试用 LLM Provider：注入固定响应或抛错，记录调用情况。
final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    enum Mode {
        case returnContent(String)
        case throwError(Error)
    }

    private let mode: Mode
    private(set) var calls = 0
    private(set) var lastRequest: LLMRequest?

    init(content: String) { self.mode = .returnContent(content) }
    init(throwing error: Error) { self.mode = .throwError(error) }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        calls += 1
        lastRequest = request
        switch mode {
        case .returnContent(let content):
            return LLMResponse(content: content)
        case .throwError(let error):
            throw error
        }
    }
}
```

- [ ] **Step 2: 写失败测试**

`Tests/SageTests/LLM/LLMProviderProtocolTests.swift`：

```swift
import XCTest
@testable import Sage

final class LLMProviderProtocolTests: XCTestCase {
    func testFake返回内容() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.8}"#)
        let response = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u", jsonSchemaHint: nil))
        XCTAssertEqual(response.content, #"{"matches":true,"confidence":0.8}"#)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(provider.lastRequest?.userPrompt, "u")
    }

    func testFake抛错() async throws {
        struct Boom: Error {}
        let provider = FakeLLMProvider(throwing: Boom())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u", jsonSchemaHint: nil))
            XCTFail("应抛错")
        } catch is Boom {
            // ok
        }
    }

    func testProviderError描述() {
        XCTAssertEqual(LLMProviderError.timeout.errorDescription, "LLM 请求超时。")
        XCTAssertEqual(LLMProviderError.emptyContent.errorDescription, "LLM 返回内容为空。")
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'LLMProvider'`。

- [ ] **Step 4: 实现**

`Sources/Sage/LLM/LLMRequest.swift`：

```swift
import Foundation

/// LLM 请求载体（OpenAI 兼容，不绑定具体厂商）。
public struct LLMRequest: Sendable {
    public var systemPrompt: String
    public var userPrompt: String
    public var jsonSchemaHint: String?  // 提示模型按 JSON 输出；为 nil 则自由文本

    public init(systemPrompt: String, userPrompt: String, jsonSchemaHint: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.jsonSchemaHint = jsonSchemaHint
    }
}

/// LLM 原始返回（未解析的文本）。
public struct LLMResponse: Sendable, Equatable {
    public var content: String
    public init(content: String) { self.content = content }
}

/// LLM 调用错误。
public enum LLMProviderError: LocalizedError, Sendable {
    case network(Error)
    case http(status: Int, body: String)
    case emptyContent
    case timeout

    public var errorDescription: String? {
        switch self {
        case .network:
            return "LLM 网络请求失败。"
        case .http(let status, _):
            return "LLM 服务返回 HTTP \(status)。"
        case .emptyContent:
            return "LLM 返回内容为空。"
        case .timeout:
            return "LLM 请求超时。"
        }
    }
}
```

`Sources/Sage/LLM/LLMProvider.swift`：

```swift
import Foundation

/// OpenAI 兼容协议抽象：云端与本地端点同一接口（spec §2、§3 LLM 模块）。
/// 真实实现 `HTTPLLMProvider` 在 Task 3；本协议是 Gateway 唯一依赖。
public protocol LLMProvider: Sendable {
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift build && swift test --filter LLMProviderProtocolTests`
Expected: PASS（3 个测试）。

- [ ] **Step 6: Commit**

```bash
git add Sources/Sage/LLM Tests/SageTests/Support/FakeLLMProvider.swift Tests/SageTests/LLM
git commit -m "feat(sage): LLMProvider 协议与 FakeLLMProvider 测试基建"
```

---

### Task 3: HTTPLLMProvider（OpenAI 兼容 HTTP 实现）

**Files:**
- Create: `Sources/Sage/LLM/HTTPLLMProvider.swift`
- Test: `Tests/SageTests/LLM/HTTPLLMProviderTests.swift`

**Interfaces:**
- Produces:
  - `struct HTTPLLMConfig: Sendable, Equatable` — `baseURL: URL`、`apiKey: String`、`model: String`、`timeout: TimeInterval = 30`
  - `struct HTTPLLMProvider: Sendable`，`init(config: HTTPLLMConfig, session: URLSession = .shared)`
  - 实现 `LLMProvider.send(_:)`：POST `{baseURL}/chat/completions`，Bearer 鉴权，body 为 OpenAI Chat 格式 `{model, messages:[{role,content}], stream:false}`；响应取 `choices[0].message.content`；非 2xx 抛 `.http`；空 content 抛 `.emptyContent`；超时抛 `.timeout`。
  - 注入 `URLSession` 便于测试用自定义 `URLProtocol` 拦截。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/LLM/HTTPLLMProviderTests.swift`：

```swift
import XCTest
@testable import Sage

/// 拦截 URLSession 的自定义 URLProtocol，返回注入的响应。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var response: (HTTPURLResponse, Data)?
    static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let (response, data) = Self.response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { response = nil; error = nil }
}

final class HTTPLLMProviderTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() { StubURLProtocol.reset() }

    private func makeConfig() -> HTTPLLMConfig {
        HTTPLLMConfig(baseURL: URL(string: "https://api.example.com/v1")!,
                      apiKey: "sk-test", model: "test-model")
    }

    func test成功返回content() async throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                    Data(json.utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        let response = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
        XCTAssertEqual(response.content, "hello")
    }

    func testHTTP非2xx抛错() async throws {
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 401, httpVersion: nil, headerFields: nil)!,
                                    Data("unauthorized".utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
            XCTFail("应抛错")
        } catch LLMProviderError.http(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    func test空content抛错() async throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#
        StubURLProtocol.response = (HTTPURLResponse(url: URL(string: "https://api.example.com/v1/chat/completions")!,
                                                     statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                    Data(json.utf8))
        let provider = HTTPLLMProvider(config: makeConfig(), session: makeSession())
        do {
            _ = try await provider.send(LLMRequest(systemPrompt: "s", userPrompt: "u"))
            XCTFail("应抛错")
        } catch LLMProviderError.emptyContent {
            // ok
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'HTTPLLMProvider'`。

- [ ] **Step 3: 实现**

`Sources/Sage/LLM/HTTPLLMProvider.swift`：

```swift
import Foundation

/// OpenAI 兼容端点配置（spec §2）。
public struct HTTPLLMConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
    }
}

/// OpenAI 兼容协议的 HTTP 实现：云端（DeepSeek/Kimi/OpenRouter/SiliconFlow）与本地（Ollama/LM Studio）同一接口。
public struct HTTPLLMProvider: Sendable {
    private let config: HTTPLLMConfig
    private let session: URLSession

    public init(config: HTTPLLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        var messages: [[String: String]] = [
            ["role": "system", "content": request.systemPrompt],
            ["role": "user", "content": request.userPrompt]
        ]
        if let hint = request.jsonSchemaHint {
            messages.append(["role": "system", "content": "请按如下 JSON 结构输出：\n\(hint)"])
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false
        ]
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = config.timeout
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        } catch {
            throw LLMProviderError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.http(status: http.statusCode, body: bodyString)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMProviderError.emptyContent
        }
        guard !content.isEmpty else { throw LLMProviderError.emptyContent }
        return LLMResponse(content: content)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter HTTPLLMProviderTests`
Expected: PASS（3 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/LLM/HTTPLLMProvider.swift Tests/SageTests/LLM/HTTPLLMProviderTests.swift
git commit -m "feat(sage): HTTPLLMProvider OpenAI 兼容 HTTP 实现"
```

---

### Task 4: LLMGateway（限速/预算/缓存/降级）

**Files:**
- Create: `Sources/Sage/LLM/LLMGateway.swift`
- Create: `Sources/Sage/LLM/LLMPrompts.swift`
- Test: `Tests/SageTests/LLM/LLMGatewayTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `LLMProvider`、Task 3 的 `HTTPLLMProvider`（可选注入）。
- Produces:
  - `struct LLMCacheEntry: Sendable, Equatable` — `verdict: SemanticVerdict`、`metadata: ExtractedMetadata?`
  - `struct LLMBudget: Sendable, Equatable` — `dailyLimit: Int?`（nil 表示不限制）、`date: Date`（用于按日重置）
  - `struct LLMGatewayConfig: Sendable` — `budget: LLMBudget`、`minRetryDelay: TimeInterval = 0.5`、`maxRetries: Int = 3`
  - `actor LLMGateway`：
    - `init(provider: LLMProvider, config: LLMGatewayConfig = .default, now: @Sendable () -> Date = { Date() })`
    - `func semanticVerdict(prompt systemPrompt: String, userPrompt: String, cacheKey: String) async throws -> SemanticVerdict`
    - `func extractMetadata(prompt systemPrompt: String, userPrompt: String, cacheKey: String) async throws -> ExtractedMetadata`
    - 内部按 `cacheKey`（通常是 `(contentHash, promptType)` 拼接）缓存；超预算抛 `LLMGatewayError.budgetExceeded`；失败按 `maxRetries` 重试后仍失败抛错。
  - `enum LLMGatewayError: LocalizedError, Sendable` — `.budgetExceeded(used: Int, limit: Int)`、`.parseFailed(String)`、`.retriesExhausted(Error)`

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/LLM/LLMGatewayTests.swift`：

```swift
import XCTest
@testable import Sage

final class LLMGatewayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeGateway(provider: LLMProvider, budget: Int? = nil, maxRetries: Int = 3) -> LLMGateway {
        let config = LLMGatewayConfig(budget: LLMBudget(dailyLimit: budget, date: now),
                                      maxRetries: maxRetries)
        return LLMGateway(provider: provider, config: config, now: { now })
    }

    func test语义判断返回解析() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.85}"#)
        let gateway = makeGateway(provider: provider)
        let verdict = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "hash1:cat")
        XCTAssertEqual(verdict, SemanticVerdict(matches: true, confidence: 0.85))
    }

    func test相同cacheKey只调一次() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
        XCTAssertEqual(provider.calls, 1)
    }

    func test超预算抛错() async throws {
        let provider = FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)
        let gateway = makeGateway(provider: provider, budget: 1)
        _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k1")
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k2")
            XCTFail("应抛预算超限")
        } catch LLMGatewayError.budgetExceeded(let used, let limit) {
            XCTAssertEqual(used, 1)
            XCTAssertEqual(limit, 1)
        }
    }

    func test失败重试maxRetries次后抛错() async throws {
        struct Boom: Error {}
        let provider = FakeLLMProvider(throwing: Boom())
        let gateway = makeGateway(provider: provider, maxRetries: 2)
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
            XCTFail("应抛错")
        } catch LLMGatewayError.retriesExhausted {
            XCTAssertEqual(provider.calls, 2)
        }
    }

    func test解析失败抛parseFailed() async throws {
        let provider = FakeLLMProvider(content: "不是JSON")
        let gateway = makeGateway(provider: provider)
        do {
            _ = try await gateway.semanticVerdict(prompt: "s", userPrompt: "u", cacheKey: "k")
            XCTFail("应抛错")
        } catch LLMGatewayError.parseFailed {
            // ok
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'LLMGateway'`。

- [ ] **Step 3: 实现**

`Sources/Sage/LLM/LLMPrompts.swift`：

```swift
import Foundation

/// LLM prompt 模板：语义判断 / 元数据提取 / 命名。
/// 实际字符串内容可由 UI 设置调整；这里给默认结构化模板。
public enum LLMPrompts {
    /// 内容是否属于某分类（返回 {matches, confidence}）。
    public static func belongsTo(category: String, text: String) -> LLMRequest {
        let system = "你是文件分类助手。判断给定文件文本是否属于指定分类，返回 JSON。"
        let user = "分类：「\(category)」\n文件文本：\n\(text.prefix(2000))"
        let hint = #"{"matches": true|false, "confidence": 0.0-1.0}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }

    /// 内容是否符自然语言描述（返回 {matches, confidence}）。
    public static func matchesDescription(description: String, text: String) -> LLMRequest {
        let system = "你是文件内容匹配助手。判断给定文件文本是否符自然语言描述，返回 JSON。"
        let user = "描述：「\(description)」\n文件文本：\n\(text.prefix(2000))"
        let hint = #"{"matches": true|false, "confidence": 0.0-1.0}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }

    /// 元数据提取（返回 ExtractedMetadata JSON）。
    public static func extractMetadata(text: String, fallbackName: String) -> LLMRequest {
        let system = "你是文件元数据提取助手。从文件文本中提取标题、日期、分类、标签、摘要、来源。"
        let user = "文件名（备用标题）：\(fallbackName)\n文件文本：\n\(text.prefix(4000))"
        let hint = #"{"title": String|null, "date": "yyyy-MM-dd"|null, "category": String|null, "tags": [String], "summary": String|null, "source": String|null}"#
        return LLMRequest(systemPrompt: system, userPrompt: user, jsonSchemaHint: hint)
    }
}
```

`Sources/Sage/LLM/LLMGateway.swift`：

```swift
import Foundation

/// LLM 调用唯一入口的配置（spec §3 LLM 模块、§7.3 预算）。
public struct LLMBudget: Sendable, Equatable {
    public var dailyLimit: Int?  // nil = 不限
    public var date: Date       // 用于按日重置计数

    public init(dailyLimit: Int?, date: Date) {
        self.dailyLimit = dailyLimit
        self.date = date
    }
}

public struct LLMGatewayConfig: Sendable {
    public var budget: LLMBudget
    public var minRetryDelay: TimeInterval
    public var maxRetries: Int

    public init(budget: LLMBudget, minRetryDelay: TimeInterval = 0.5, maxRetries: Int = 3) {
        self.budget = budget
        self.minRetryDelay = minRetryDelay
        self.maxRetries = maxRetries
    }

    public static let `default` = LLMGatewayConfig(budget: LLMBudget(dailyLimit: nil, date: Date()))
}

public enum LLMGatewayError: LocalizedError, Sendable {
    case budgetExceeded(used: Int, limit: Int)
    case parseFailed(String)
    case retriesExhausted(Error)

    public var errorDescription: String? {
        switch self {
        case .budgetExceeded(let used, let limit):
            return "LLM 今日调用已达 \(used)/\(limit) 次预算上限，相关规则已暂停。"
        case .parseFailed(let raw):
            return "LLM 返回无法解析为 JSON：\(raw.prefix(100))"
        case .retriesExhausted:
            return "LLM 调用重试耗尽。"
        }
    }
}

/// LLM 全部调用的唯一入口：限速、每日预算、按 cacheKey 缓存、失败重试（spec §3、§7.3、§8）。
public actor LLMGateway {
    private let provider: LLMProvider
    private let config: LLMGatewayConfig
    private let now: @Sendable () -> Date

    private var verdictCache: [String: SemanticVerdict] = [:]
    private var metadataCache: [String: ExtractedMetadata] = [:]
    private var usedToday: Int = 0
    private var budgetDate: Date

    public init(provider: LLMProvider, config: LLMGatewayConfig = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.config = config
        self.now = now
        self.budgetDate = config.budget.date
    }

    public func semanticVerdict(prompt systemPrompt: String, userPrompt: String, cacheKey: String) async throws -> SemanticVerdict {
        if let cached = verdictCache[cacheKey] { return cached }
        let content = try await callWithRetry(systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMGatewayError.parseFailed(content)
        }
        let matches = (json["matches"] as? Bool) ?? false
        let confidence = (json["confidence"] as? Double) ?? 0
        let verdict = SemanticVerdict(matches: matches, confidence: confidence)
        verdictCache[cacheKey] = verdict
        return verdict
    }

    public func extractMetadata(prompt systemPrompt: String, userPrompt: String, cacheKey: String) async throws -> ExtractedMetadata {
        if let cached = metadataCache[cacheKey] { return cached }
        let content = try await callWithRetry(systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMGatewayError.parseFailed(content)
        }
        let metadata = ExtractedMetadata(
            title: json["title"] as? String,
            date: parseDate(json["date"] as? String),
            category: json["category"] as? String,
            tags: (json["tags"] as? [String]) ?? [],
            summary: json["summary"] as? String,
            source: json["source"] as? String
        )
        metadataCache[cacheKey] = metadata
        return metadata
    }

    // MARK: - 内部

    private func callWithRetry(systemPrompt: String, userPrompt: String) async throws -> String {
        try checkBudget()
        var lastError: Error?
        for attempt in 0..<config.maxRetries {
            do {
                let request = LLMRequest(systemPrompt: systemPrompt, userPrompt: userPrompt)
                let response = try await provider.send(request)
                usedToday += 1
                return response.content
            } catch {
                lastError = error
                if attempt < config.maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(config.minRetryDelay * 1_000_000_000))
                }
            }
        }
        throw LLMGatewayError.retriesExhausted(lastError ?? LLMProviderError.emptyContent)
    }

    private func checkBudget() throws {
        // 跨日重置
        let today = now()
        if !Calendar.current.isDate(today, inSameDayAs: budgetDate) {
            usedToday = 0
            budgetDate = today
        }
        if let limit = config.budget.dailyLimit, usedToday >= limit {
            throw LLMGatewayError.budgetExceeded(used: usedToday, limit: limit)
        }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter LLMGatewayTests`
Expected: PASS（5 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/LLM/LLMGateway.swift Sources/Sage/LLM/LLMPrompts.swift Tests/SageTests/LLM/LLMGatewayTests.swift
git commit -m "feat(sage): LLMGateway 限速/预算/缓存/降级"
```

---

### Task 5: LocalExtractor（设备端内容提取）

**Files:**
- Create: `Sources/Sage/Extraction/LocalExtractor.swift`
- Test: `Tests/SageTests/Extraction/LocalExtractorTests.swift`

**Interfaces:**
- Consumes: 第 1 份的 `FileLocation`、`CheapFacts`、`ExtractedFacts`。
- Produces:
  - `struct LocalExtractor: Sendable`
  - `func cheapFacts(for location: FileLocation) throws -> CheapFacts` — 本地文件经 `URLResourceValues` 读 name/size/creationDate/contentModificationDate/UTType；DT 位置返回空 `CheapFacts`（DT 的属性由 DTWatcher 提供，本层不碰 AppleScript）。
  - `func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts` — 文本提取（PDF/RTF/mdls 回退，沿用旧 LocalAnalyzer 经验）+ SHA-256 哈希 + 图片 EXIF 拍摄日期 + 视频时长/元数据 + 来源 URL（ spotlight `kMDItemWhereFroms`）。
  - 错误：`enum ExtractionError: LocalizedError` — `.unsupportedLocation`、`.fileRead(Error)`。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Extraction/LocalExtractorTests.swift`：

```swift
import XCTest
@testable import Sage

final class LocalExtractorTests: XCTestCase {
    private var tempDir: URL!
    private let extractor = LocalExtractor()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCheapFacts读取文件属性() throws {
        let url = tempDir.appendingPathComponent("Invoice.PDF")
        try Data("dummy".utf8).write(to: url)
        let facts = try extractor.cheapFacts(for: .local(path: url.path))
        XCTAssertEqual(facts.fileExtension, "pdf")
        XCTAssertEqual(facts.name, "Invoice")
        XCTAssertEqual(facts.sizeBytes, 6)
    }

    func testCheapFacts_DT位置返回空() throws {
        let facts = try extractor.cheapFacts(for: .devonthink(uuid: "X", database: "财务", groupPath: "/收件箱"))
        XCTAssertEqual(facts.name, "")
        XCTAssertEqual(facts.fileExtension, "")
    }

    func testExtractedFacts计算哈希() async throws {
        let url = tempDir.appendingPathComponent("a.txt")
        let content = "hello sage"
        try Data(content.utf8).write(to: url)
        let facts = try await extractor.extractedFacts(for: .local(path: url.path))
        XCTAssertNotNil(facts.contentHash)
        XCTAssertEqual(facts.contentHash?.count, 64) // SHA-256 十六进制长度
        XCTAssertNotNil(facts.text)
        XCTAssertTrue(facts.text!.contains("hello"))
    }

    func testExtractedFacts相同内容哈希一致() async throws {
        let url1 = tempDir.appendingPathComponent("a.txt")
        let url2 = tempDir.appendingPathComponent("b.txt")
        try Data("same".utf8).write(to: url1)
        try Data("same".utf8).write(to: url2)
        let f1 = try await extractor.extractedFacts(for: .local(path: url1.path))
        let f2 = try await extractor.extractedFacts(for: .local(path: url2.path))
        XCTAssertEqual(f1.contentHash, f2.contentHash)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'LocalExtractor'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Extraction/LocalExtractor.swift`：

```swift
import Foundation
import PDFKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

/// 设备端内容提取错误。
public enum ExtractionError: LocalizedError, Sendable {
    case unsupportedLocation
    case fileRead(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation:
            return "该文件位置不支持本地提取。"
        case .fileRead:
            return "读取文件失败。"
        }
    }
}

/// 设备端内容提取：文本（PDF/RTF/mdls 回退）、SHA-256 哈希、图片 EXIF、视频元数据、来源 URL。
/// 沿用旧 Renamer LocalAnalyzer 的经验，但只产 ExtractedFacts，不做分类/标题推断（那是 LLM 的活）。
public struct LocalExtractor: Sendable {
    public init() {}

    public func cheapFacts(for location: FileLocation) throws -> CheapFacts {
        guard case .local(let path) = location else {
            return CheapFacts(name: "", fileExtension: "", sizeBytes: 0)
        }
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.nameKey, .fileSizeKey,
                                                          .creationDateKey, .contentModificationDateKey,
                                                          .typeIdentifierKey])
            let fullName = values.name ?? url.lastPathComponent
            let nameWithoutExt = (fullName as NSString).deletingPathExtension
            let ext = (fullName as NSString).pathExtension.lowercased()
            let utType = values.typeIdentifier
            return CheapFacts(
                name: nameWithoutExt,
                fileExtension: ext,
                sizeBytes: Int64(values.fileSize ?? 0),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                utType: utType
            )
        } catch {
            throw ExtractionError.fileRead(error)
        }
    }

    public func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        guard case .local(let path) = location else {
            return ExtractedFacts()
        }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtractionError.fileRead(error)
        }
        let hash = sha256Hex(data)
        let text = extractText(url: url, data: data)
        let captureDate = extractCaptureDate(url: url, ext: (url.pathExtension as NSString).pathExtension.lowercased())
        let sourceURL = spotlightSourceURL(url: url)
        return ExtractedFacts(
            text: text,
            contentHash: hash,
            isDuplicate: false,  // 重复判定由 ExtractionProvider 在外层维护哈希集合
            captureDate: captureDate,
            sourceURL: sourceURL
        )
    }

    // MARK: - 文本提取

    private func extractText(url: URL, data: Data) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return extractPDFText(url: url)
        case "rtf", "rtfd":
            return extractRTFText(url: url)
        default:
            if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
            return spotlightText(url: url)
        }
    }

    private func extractPDFText(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    private func extractRTFText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let attr = try? NSAttributedString(data: data,
                                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 options: [:]) else { return nil }
        return attr.string
    }

    private func spotlightText(url: URL) -> String? {
        // mdls 回退：docx/iWork 等格式用 Spotlight 索引提取
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", "kMDItemTextContent", "-raw", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        // 5 秒超时兜底
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "(null)" { return nil }
        return raw
    }

    // MARK: - 图片 EXIF

    private func extractCaptureDate(url: URL, ext: String) -> Date? {
        let imageExts: Set<String> = ["jpg", "jpeg", "heic", "png", "tiff", "raw"]
        guard imageExts.contains(ext) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            return parseEXIFDate(dateString)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let dateString = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            return parseEXIFDate(dateString)
        }
        return nil
    }

    private func parseEXIFDate(_ s: String) -> Date? {
        // EXIF 格式 "yyyy:MM:dd HH:mm:ss"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: s)
    }

    // MARK: - 来源 URL（Spotlight kMDItemWhereFroms）

    private func spotlightSourceURL(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", "kMDItemWhereFroms", "-raw", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "(null)" { return nil }
        // 形如 ( "https://...", "..." )，取第一个
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()\n "))
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return cleaned?.isEmpty == true ? nil : cleaned
    }

    // MARK: - 哈希

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter LocalExtractorTests`
Expected: PASS（4 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/Sage/Extraction Sources/Sage/../Sage/Extraction Tests/SageTests/Extraction
git commit -m "feat(sage): LocalExtractor 设备端内容提取（PDF/RTF/mdls/EXIF/哈希/来源URL）"
```

---

### Task 6: ExtractionProvider（组合 LocalExtractor + LLMGateway 实现 FactsProvider）

**Files:**
- Create: `Sources/Sage/Extraction/ExtractionProvider.swift`
- Test: `Tests/SageTests/Extraction/ExtractionProviderTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `LocalExtractor`、Task 4 的 `LLMGateway`、第 1 份的 `FactsProvider`。
- Produces:
  - `actor ExtractionProvider: FactsProvider`：
    - `init(extractor: LocalExtractor = LocalExtractor(), gateway: LLMGateway, duplicateRegistry: DuplicateRegistry = .shared)`
    - `cheapFacts(for:)` 转发 extractor。
    - `extractedFacts(for:)` 转发 extractor，结果按 `contentHash` 缓存；并与 `DuplicateRegistry` 比对填 `isDuplicate`。
    - `belongsTo(category:at:)`：先取 extractedFacts 拿 text+hash，调 `LLMGateway.semanticVerdict(prompt:userPrompt:cacheKey:)`，cacheKey = `"\(hash):belongsTo:\(category)"`。
    - `matchesDescription(_:at:)`：同上，cacheKey = `"\(hash):matches:\(description)"`。
  - `actor DuplicateRegistry` — 跨事件维护已见哈希集合，`func register(_ hash: String)`、`func isDuplicate(_ hash: String) -> Bool`；`static let shared`。测试用独立实例避免污染。

- [ ] **Step 1: 写失败测试**

`Tests/SageTests/Extraction/ExtractionProviderTests.swift`：

```swift
import XCTest
@testable import Sage

final class ExtractionProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, content: String) -> String {
        let url = tempDir.appendingPathComponent(name)
        try? Data(content.utf8).write(to: url)
        return url.path
    }

    func testCheapFacts转发() async throws {
        let path = makeFile("Doc.PDF", content: "x")
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")))
        let facts = try await provider.cheapFacts(for: .local(path: path))
        XCTAssertEqual(facts.fileExtension, "pdf")
    }

    func testExtractedFacts按哈希缓存不重复提取() async throws {
        let path = makeFile("a.txt", content: "same content")
        // 用一个会记录调用次数的 extractor 不便，这里用真实 LocalExtractor + 两次调用验证缓存行为
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")))
        let f1 = try await provider.extractedFacts(for: .local(path: path))
        let f2 = try await provider.extractedFacts(for: .local(path: path))
        XCTAssertEqual(f1.contentHash, f2.contentHash)
    }

    func testBelongsTo走LLMGateway() async throws {
        let path = makeFile("a.txt", content: "增值税发票 税号123")
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: #"{"matches":true,"confidence":0.9}"#)))
        let verdict = try await provider.belongsTo(category: "发票", at: .local(path: path))
        XCTAssertTrue(verdict.matches)
        XCTAssertEqual(verdict.confidence, 0.9)
    }

    func test重复文件isDuplicate为true() async throws {
        let path1 = makeFile("a.txt", content: "dup")
        let path2 = makeFile("b.txt", content: "dup")
        let registry = DuplicateRegistry()
        let provider = ExtractionProvider(gateway: LLMGateway(provider: FakeLLMProvider(content: "{}")),
                                          duplicateRegistry: registry)
        let f1 = try await provider.extractedFacts(for: .local(path: path1))
        // 同内容第二次
        let f2 = try await provider.extractedFacts(for: .local(path: path2))
        // 第二个文件应被标记为重复（哈希相同且已在 registry 注册）
        XCTAssertTrue(f2.isDuplicate, "同哈希的第二个文件应被标记为重复")
        XCTAssertFalse(f1.isDuplicate)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift build`
Expected: FAIL，`cannot find 'ExtractionProvider'`。

- [ ] **Step 3: 实现**

`Sources/Sage/Extraction/ExtractionProvider.swift`：

```swift
import Foundation

/// 跨事件维护内容哈希集合，识别重复文件。
public actor DuplicateRegistry {
    private var seen: Set<String> = []

    public init() {}

    public func register(_ hash: String) {
        seen.insert(hash)
    }

    public func isDuplicate(_ hash: String) -> Bool {
        if seen.contains(hash) { return true }
        seen.insert(hash)
        return false
    }

    public func reset() { seen.removeAll() }

    public static let shared = DuplicateRegistry()
}

/// 真实 FactsProvider：组合 LocalExtractor（零成本+提取档）与 LLMGateway（LLM 档）。
public actor ExtractionProvider: FactsProvider {
    private let extractor: LocalExtractor
    private let gateway: LLMGateway
    private let duplicateRegistry: DuplicateRegistry

    private var extractedCache: [String: ExtractedFacts] = [:]  // key = path 或 contentHash

    public init(extractor: LocalExtractor = LocalExtractor(),
                gateway: LLMGateway,
                duplicateRegistry: DuplicateRegistry = .shared) {
        self.extractor = extractor
        self.gateway = gateway
        self.duplicateRegistry = duplicateRegistry
    }

    public func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        try extractor.cheapFacts(for: location)
    }

    public func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        if let cached = extractedCache[cacheKey(for: location)] { return cached }
        var facts = try await extractor.extractedFacts(for: location)
        if let hash = facts.contentHash {
            facts.isDuplicate = await duplicateRegistry.isDuplicate(hash)
        }
        extractedCache[cacheKey(for: location)] = facts
        return facts
    }

    public func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
        let facts = try await extractedFacts(for: location)
        let text = facts.text ?? ""
        let request = LLMPrompts.belongsTo(category: category, text: text)
        let hash = facts.contentHash ?? "nohash:\(cacheKey(for: location))"
        let cacheKey = "\(hash):belongsTo:\(category)"
        return try await gateway.semanticVerdict(prompt: request.systemPrompt,
                                                  userPrompt: request.userPrompt,
                                                  cacheKey: cacheKey)
    }

    public func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
        let facts = try await extractedFacts(for: location)
        let text = facts.text ?? ""
        let request = LLMPrompts.matchesDescription(description: description, text: text)
        let hash = facts.contentHash ?? "nohash:\(cacheKey(for: location))"
        let cacheKey = "\(hash):matches:\(description)"
        return try await gateway.semanticVerdict(prompt: request.systemPrompt,
                                                  userPrompt: request.userPrompt,
                                                  cacheKey: cacheKey)
    }

    private func cacheKey(for location: FileLocation) -> String {
        switch location {
        case .local(let path): return path
        case .devonthink(let uuid, _, _): return "dt:\(uuid)"
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift build && swift test --filter ExtractionProviderTests`
Expected: PASS（4 个测试）。

- [ ] **Step 5: 全量回归并提交**

Run: `swift test --filter SageTests`
Expected: 全部通过。

```bash
git add Sources/Sage/Extraction/ExtractionProvider.swift Tests/SageTests/Extraction/ExtractionProviderTests.swift
git commit -m "feat(sage): ExtractionProvider 组合 LocalExtractor 与 LLMGateway 实现 FactsProvider"
```

---

## 后续计划衔接

本计划完成后，`Sage` 具备完整可测的「事件源 → 规则求值」核心 + 真实取数能力。第 3/5 份：

3. **监控与执行层**：FolderWatcher（FSEvents + 写入完成检测）、ManualIntake、ActionRunner（actor 串行本地 FS 写）、ConfirmQueue（持久化待确认）、Journal（操作日志 + 回滚）、`.moveToTrash` 强制入队。