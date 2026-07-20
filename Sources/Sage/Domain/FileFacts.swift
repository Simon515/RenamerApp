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
