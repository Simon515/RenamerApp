import Foundation
import SwiftUI

@MainActor
@Observable
final class TaskListViewModel {
    var tasks: [OrganizationTask] = []

    private var storageURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appending(path: "tasks.json")
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path()) else { return }
        let data = try Data(contentsOf: storageURL)
        tasks = try JSONDecoder().decode([OrganizationTask].self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(tasks)
        try data.write(to: storageURL)
    }

    func add(_ task: OrganizationTask) throws {
        tasks.append(task)
        try save()
    }

    func delete(_ task: OrganizationTask) throws {
        tasks.removeAll { $0.id == task.id }
        try save()
    }
}
