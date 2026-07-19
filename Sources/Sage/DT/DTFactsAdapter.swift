import CryptoKit
import Foundation

/// FactsProvider 包装：.devonthink 位置由 DT 记录属性 + 纯文本导出填充（spec §5）；
/// .local 位置全部转发内层 provider。
public struct DTFactsAdapter: FactsProvider {
    private let local: any FactsProvider
    private let runner: any AppleScriptRunning

    /// DT «class isot» 日期形如 2026-07-01T08:00:00（本地时区、无时差后缀）。
    private static let isot: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(local: any FactsProvider, runner: any AppleScriptRunning = NSAppleScriptRunner()) {
        self.local = local
        self.runner = runner
    }

    public func cheapFacts(for location: FileLocation) async throws -> CheapFacts {
        guard case .devonthink(let uuid, _, _) = location else {
            return try await local.cheapFacts(for: location)
        }
        let raw = try await runner.run(DTScriptBuilder.factsScript(uuid: uuid))
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 5 else { throw DTError.scriptFailed("记录属性格式异常：\(raw)") }
        let fullName = parts[0]
        let ext = (fullName as NSString).pathExtension.lowercased()
        let stem = ext.isEmpty ? fullName : (fullName as NSString).deletingPathExtension
        return CheapFacts(name: stem, fileExtension: ext,
                          sizeBytes: Int64(parts[2]) ?? 0,
                          createdAt: Self.isot.date(from: parts[3]),
                          modifiedAt: Self.isot.date(from: parts[4]),
                          utType: nil)
    }

    public func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        guard case .devonthink(let uuid, _, _) = location else {
            return try await local.extractedFacts(for: location)
        }
        let text = try await runner.run(DTScriptBuilder.plainTextScript(uuid: uuid))
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ExtractedFacts(text: text, contentHash: hash)
    }

    public func belongsTo(category: String, at location: FileLocation) async throws -> SemanticVerdict {
        guard case .devonthink = location else {
            return try await local.belongsTo(category: category, at: location)
        }
        let facts = try await extractedFacts(for: location)
        return try await semantic().belongsTo(category: category, text: facts.text ?? "",
                                              cacheKey: facts.contentHash ?? "dt:nohash")
    }

    public func matchesDescription(_ description: String, at location: FileLocation) async throws -> SemanticVerdict {
        guard case .devonthink = location else {
            return try await local.matchesDescription(description, at: location)
        }
        let facts = try await extractedFacts(for: location)
        return try await semantic().matchesDescription(description, text: facts.text ?? "",
                                                       cacheKey: facts.contentHash ?? "dt:nohash")
    }

    private func semantic() throws -> ExtractionProvider {
        guard let extraction = local as? ExtractionProvider else {
            throw DTError.scriptFailed("DT 位置的 LLM 条件需要 ExtractionProvider")
        }
        return extraction
    }
}
