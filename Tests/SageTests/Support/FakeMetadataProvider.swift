import Foundation
@testable import Sage

final class FakeMetadataProvider: MetadataProviding, @unchecked Sendable {
    var result: ExtractedMetadata
    private(set) var calls = 0
    init(result: ExtractedMetadata) { self.result = result }
    func metadata(for location: FileLocation) async throws -> ExtractedMetadata {
        calls += 1
        return result
    }
}
