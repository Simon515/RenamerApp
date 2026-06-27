import Foundation
import SwiftUI

@MainActor
@Observable
final class MainViewModel {
    var plan: OrganizationPlan?
    var isAnalyzing = false
    var errorMessage: String?

    private let scanner = FileScanner()
    private let localAnalyzer = LocalAnalyzer()
    private let duplicateDetector = DuplicateDetector()

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let items = try await scanner.scan(folders: folders)
            var analyses: [FileAnalysis] = []
            for item in items {
                analyses.append(try await localAnalyzer.analyze(item: item))
            }
            let duplicates = try await duplicateDetector.detectDuplicates(in: items)
            let engine = NamingEngine(template: template, destination: destination)
            plan = try engine.buildPlan(taskID: task?.id, items: items, analyses: analyses, duplicateGroups: duplicates)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func execute(plan: OrganizationPlan, taskName: String) async {
        do {
            let record = try await Organizer().execute(plan: plan, taskName: taskName)
            try await RollbackService().save(record: record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
