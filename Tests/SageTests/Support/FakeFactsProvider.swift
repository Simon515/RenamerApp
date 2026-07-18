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
