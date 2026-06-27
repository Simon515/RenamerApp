import Foundation

actor RollbackService {
    private let recordsURL: URL

    init(recordsURL: URL? = nil) {
        self.recordsURL = recordsURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.renamer.records", isDirectory: true)
    }

    func save(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        let url = recordsURL.appending(path: "\(record.id.uuidString).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url)
    }

    func rollback(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        for move in record.moves {
            switch move.operation {
            case .move:
                try fm.moveItem(at: move.destination, to: move.source)
            case .copy:
                try fm.removeItem(at: move.destination)
            }
        }
    }
}
