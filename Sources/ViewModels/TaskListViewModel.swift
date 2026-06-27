import Foundation
import SwiftUI

@MainActor
@Observable
final class TaskListViewModel {
    var tasks: [OrganizationTask] = []
    /// 使用 `SettingsViewModel` 中集中定义的默认模板，保持一致性。
    var templates: [NamingTemplate] = SettingsViewModel.defaultTemplates

    private var storageURL: URL {
        guard let supportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            return FileManager.default.temporaryDirectory.appending(path: "renamer_tasks.json")
        }
        return supportURL.appending(path: "Renamer/tasks.json")
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path()) else { return }
        let data = try Data(contentsOf: storageURL)
        tasks = try JSONDecoder().decode([OrganizationTask].self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(tasks)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
