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
    public var minInterval: TimeInterval  // 两次真实 provider 调用的最小间隔；0 表示不限速
    public var cacheCapacity: Int         // 判定/元数据缓存的容量上限

    public init(budget: LLMBudget, minRetryDelay: TimeInterval = 0.5, maxRetries: Int = 3,
                minInterval: TimeInterval = 0, cacheCapacity: Int = 500) {
        self.budget = budget
        self.minRetryDelay = minRetryDelay
        self.maxRetries = maxRetries
        self.minInterval = minInterval
        self.cacheCapacity = cacheCapacity
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

    private var verdictCache: BoundedCache<String, SemanticVerdict>
    private var metadataCache: BoundedCache<String, ExtractedMetadata>
    private var usedToday: Int = 0
    private var budgetDate: Date
    private var nextAllowedCallTime: Date = .distantPast  // 限速：下一次真实调用最早可发起时刻

    public init(provider: LLMProvider, config: LLMGatewayConfig = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.config = config
        self.now = now
        self.budgetDate = config.budget.date
        self.verdictCache = BoundedCache(capacity: config.cacheCapacity)
        self.metadataCache = BoundedCache(capacity: config.cacheCapacity)
    }

    public func semanticVerdict(prompt systemPrompt: String, userPrompt: String, cacheKey: String) async throws -> SemanticVerdict {
        if let cached = verdictCache[cacheKey] { return cached }
        let content = try await callWithRetry(systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMGatewayError.parseFailed(content)
        }
        let matches = (json["matches"] as? Bool) ?? false
        // 缺省置信度视为 1.0：模型明确 matches:true 但省略 confidence 时不应被阈值判否。
        let confidence = (json["confidence"] as? Double) ?? 1.0
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
        // 先原子占用预算额度（同步段无挂起点，避免并发 TOCTOU 超支），失败再回退。
        try reserveBudget()
        do {
            let content = try await performCall(systemPrompt: systemPrompt, userPrompt: userPrompt)
            return content
        } catch {
            releaseBudget()
            throw error
        }
    }

    private func performCall(systemPrompt: String, userPrompt: String) async throws -> String {
        var lastError: Error?
        for attempt in 0..<config.maxRetries {
            await throttle()  // 限速：两次真实调用间隔不足 minInterval 时补足
            do {
                let request = LLMRequest(systemPrompt: systemPrompt, userPrompt: userPrompt)
                let response = try await provider.send(request)
                return response.content
            } catch {
                lastError = error
                // 非瞬态错误（HTTP 4xx，429 除外）不重试，直接退出。
                guard isRetryable(error) else { break }
                if attempt < config.maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(config.minRetryDelay * 1_000_000_000))
                }
            }
        }
        throw LLMGatewayError.retriesExhausted(lastError ?? LLMProviderError.emptyContent)
    }

    /// 是否值得重试：仅网络错误/超时/5xx/429 视为瞬态，其余（含 HTTP 4xx）不重试。
    private func isRetryable(_ error: Error) -> Bool {
        if let providerError = error as? LLMProviderError {
            switch providerError {
            case .network, .timeout, .emptyContent:
                return true
            case .http(let status, _):
                if status == 429 { return true }
                if (400..<500).contains(status) { return false }  // 401/400/403/404 等非瞬态
                return true  // 5xx
            }
        }
        return true  // 未知错误保守重试
    }

    /// 限速：按 minInterval 为每次真实调用预留时间片，缓存命中不进入此路径故不计入。
    private func throttle() async {
        guard config.minInterval > 0 else { return }
        let current = now()
        let scheduled = max(current, nextAllowedCallTime)
        nextAllowedCallTime = scheduled.addingTimeInterval(config.minInterval)
        let delay = scheduled.timeIntervalSince(current)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 原子占用一个预算额度（同步、无挂起点）。
    private func reserveBudget() throws {
        let today = now()
        if !Calendar.current.isDate(today, inSameDayAs: budgetDate) {
            usedToday = 0
            budgetDate = today
        }
        if let limit = config.budget.dailyLimit, usedToday >= limit {
            throw LLMGatewayError.budgetExceeded(used: usedToday, limit: limit)
        }
        usedToday += 1
    }

    /// 调用失败时回退此前占用的额度。
    private func releaseBudget() {
        if usedToday > 0 { usedToday -= 1 }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}