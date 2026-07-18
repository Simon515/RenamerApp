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
