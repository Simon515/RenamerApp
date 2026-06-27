import Foundation
import CryptoKit

actor DuplicateDetector {
    func detectDuplicates(in items: [FileItem]) async throws -> [DuplicateGroup] {
        var groups: [String: [FileItem]] = [:]
        for item in items {
            let hash = try hashFile(at: item.url)
            groups[hash, default: []].append(item)
        }
        return groups
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: UUID(), hash: $0.key, items: $0.value, keepIndex: 0) }
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
