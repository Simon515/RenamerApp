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

    struct CloudConfiguration: Sendable {
        let baseURL: URL
        let apiKey: String
        let model: String
    }

    var cloudConfig: CloudConfiguration?

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let items = try await scanner.scan(folders: folders)
            var analyses: [FileAnalysis] = []
            var textsByID: [UUID: String] = [:]
            for item in items {
                let text = (try? await localAnalyzer.extractText(for: item)) ?? ""
                textsByID[item.id] = text
                analyses.append(try await localAnalyzer.analyze(item: item))
            }

            if task?.useCloudAI == true, let config = cloudConfig {
                let cloudAnalyzer = CloudAnalyzer(baseURL: config.baseURL, apiKey: config.apiKey, model: config.model)
                for i in analyses.indices {
                    let text = textsByID[analyses[i].id] ?? ""
                    if let enhanced = try? await cloudAnalyzer.enhance(analyses[i], text: text) {
                        analyses[i] = enhanced
                    }
                }
            }

            let duplicates = try await duplicateDetector.detectDuplicates(in: items)
            let engine = NamingEngine(template: template, destination: destination)
            plan = try engine.buildPlan(
                taskID: task?.id,
                items: items,
                analyses: analyses,
                duplicateGroups: duplicates,
                exportTargets: task?.exportTargets ?? []
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove = .copy) async {
        do {
            let record = try await Organizer().execute(plan: plan, taskName: taskName, operation: operation)
            try await RollbackService().save(record: record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
