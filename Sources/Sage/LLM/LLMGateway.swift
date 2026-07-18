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