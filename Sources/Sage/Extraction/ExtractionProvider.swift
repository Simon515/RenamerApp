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

    private var extractedCache: BoundedCache<String, ExtractedFacts>  // key = path 或 contentHash

    public init(extractor: LocalExtractor = LocalExtractor(),
                gateway: LLMGateway,
                duplicateRegistry: DuplicateRegistry = .shared,
                cacheCapacity: Int = 500) {
        self.extractor = extractor
        self.gateway = gateway
        self.duplicateRegistry = duplicateRegistry
        self.extractedCache = BoundedCache(capacity: cacheCapacity)
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