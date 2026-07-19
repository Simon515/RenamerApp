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
