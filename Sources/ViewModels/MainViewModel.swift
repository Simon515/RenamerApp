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

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL, operation: CopyOrMove = .copy) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let items = try await scanner.scan(folders: folders)
            var analyses: [FileAnalysis] = []
            var textsByID: [UUID: String] = [:]
            var failureCount = 0
            for item in items {
                let text = (try? await localAnalyzer.extractText(for: item)) ?? ""
                textsByID[item.id] = text
                do {
                    analyses.append(try await localAnalyzer.analyze(item: item))
                } catch {
                    failureCount += 1
                    analyses.append(FileAnalysis(
                        id: item.id,
                        title: item.url.deletingPathExtension().lastPathComponent,
                        date: item.creationDate ?? item.modificationDate,
                        category: nil,
                        tags: [],
                        source: nil,
                        summary: nil,
                        confidence: 0.0
                    ))
                }
            }

            if failureCount > 0 {
                errorMessage = "\(failureCount) files could not be analyzed"
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
                exportTargets: task?.exportTargets ?? [],
                operation: task?.operation ?? operation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove? = nil) async {
        let effectiveOperation = operation ?? plan.operation
        do {
            let record = try await Organizer().execute(plan: plan, taskName: taskName, operation: effectiveOperation)
            try await RollbackService().save(record: record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
