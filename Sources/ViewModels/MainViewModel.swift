import Foundation
import SwiftUI

@MainActor
@Observable
final class MainViewModel {
    var plan: OrganizationPlan?
    var isAnalyzing = false
    var errorMessage: String?
    var successMessage: String?
    var settings: SettingsViewModel?

    var cloudConfig: CloudConfiguration?

    private let scanner = FileScanner()
    private let localAnalyzer = LocalAnalyzer()
    private let duplicateDetector = DuplicateDetector()

    // 保留最近一次分析参数，以便在重复文件保留选择变化时重建计划。
    private var lastTemplate: NamingTemplate?
    private var lastDestination: URL?
    private var lastItems: [FileItem]?
    private var lastExportTargets: [ExportTarget]?
    private var lastOperation: CopyOrMove?

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL, operation: CopyOrMove = .copy) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            // 每次分析前同步设置中的云端配置。
            if let settings {
                cloudConfig = settings.cloudConfiguration
            }

            let scanResult = await scanner.scan(folders: folders)
            guard !Task.isCancelled else { return }
            let items = scanResult.items
            var analyses: [FileAnalysis] = []
            var textsByID: [UUID: String] = [:]
            var failureCount = 0

            // 本地分析并发执行，提高大目录处理速度。
            await withTaskGroup(of: (item: FileItem, text: String, analysis: FileAnalysis, failed: Bool).self) { group in
                for item in items {
                    group.addTask { [localAnalyzer] in
                        let text = (try? await localAnalyzer.extractText(for: item)) ?? ""
                        do {
                            let analysis = try await localAnalyzer.analyze(item: item, text: text)
                            return (item, text, analysis, false)
                        } catch {
                            let fallback = FileAnalysis(
                                id: item.id,
                                title: item.url.deletingPathExtension().lastPathComponent,
                                date: item.creationDate ?? item.modificationDate,
                                category: nil,
                                tags: [],
                                source: nil,
                                summary: nil,
                                confidence: 0.0
                            )
                            return (item, text, fallback, true)
                        }
                    }
                }

                for await result in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    textsByID[result.item.id] = result.text
                    analyses.append(result.analysis)
                    if result.failed {
                        failureCount += 1
                    }
                }
            }
            guard !Task.isCancelled else { return }

            // 保持 analyses 与 items 顺序一致，便于后续计划构建。
            let analysisByID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.id, $0) })
            analyses = items.compactMap { analysisByID[$0.id] }

            var cloudFailureCount = 0
            if task?.useCloudAI == true, let config = cloudConfig {
                let cloudAnalyzer = CloudAnalyzer(baseURL: config.baseURL, apiKey: config.apiKey, model: config.model)
                // 云端请求限速：最多 3 个并发，避免触发服务商速率限制。
                let maxConcurrentCloud = 3
                let total = analyses.count
                var index = 0

                while index < total {
                    if Task.isCancelled { break }
                    let batchEnd = min(index + maxConcurrentCloud, total)
                    let batchEntries = Array(index..<batchEnd).map { (
                        index: $0,
                        analysis: analyses[$0],
                        text: textsByID[analyses[$0].id] ?? ""
                    ) }
                    let results: [(index: Int, analysis: FileAnalysis, succeeded: Bool)] = await withTaskGroup(of: (Int, FileAnalysis, Bool).self) { group in
                        for entry in batchEntries {
                            group.addTask {
                                do {
                                    let enhanced = try await cloudAnalyzer.enhance(entry.analysis, text: entry.text)
                                    return (entry.index, enhanced, true)
                                } catch {
                                    return (entry.index, entry.analysis, false)
                                }
                            }
                        }
                        var collected: [(Int, FileAnalysis, Bool)] = []
                        for await result in group {
                            collected.append(result)
                        }
                        return collected
                    }
                    for result in results {
                        analyses[result.index] = result.analysis
                        if !result.succeeded {
                            cloudFailureCount += 1
                        }
                    }
                    index = batchEnd
                }
            }
            guard !Task.isCancelled else { return }

            let detectionResult = await duplicateDetector.detectDuplicates(in: items)
            guard !Task.isCancelled else { return }
            let engine = NamingEngine(template: template, destination: destination)
            lastTemplate = template
            lastDestination = destination
            lastItems = items
            lastExportTargets = task?.exportTargets ?? []
            lastOperation = task?.operation ?? operation
            plan = try engine.buildPlan(
                taskID: task?.id,
                items: items,
                analyses: analyses,
                duplicateGroups: detectionResult.groups,
                exportTargets: lastExportTargets ?? [],
                operation: lastOperation ?? operation
            )

            var messages: [String] = []
            if scanResult.inaccessibleCount > 0 {
                messages.append("\(scanResult.inaccessibleCount) 个目录无法访问")
            }
            if failureCount > 0 {
                messages.append("\(failureCount) 个文件无法分析")
            }
            if detectionResult.inaccessibleCount > 0 {
                messages.append("\(detectionResult.inaccessibleCount) 个文件无法计算哈希以检测重复")
            }
            if cloudFailureCount > 0 {
                messages.append("云端增强失败 \(cloudFailureCount) 个文件")
            }
            if !messages.isEmpty {
                errorMessage = messages.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 当用户在预览中调整重复文件保留项时，使用原始参数重建操作列表。
    func rebuildPlan() async {
        guard let plan,
              let lastTemplate,
              let lastDestination,
              let lastItems else { return }

        let engine = NamingEngine(template: lastTemplate, destination: lastDestination)
        do {
            let enabledBySource = Dictionary(uniqueKeysWithValues: plan.operations.map { ($0.source, $0.isEnabled) })
            var newPlan = try engine.buildPlan(
                taskID: plan.taskID,
                items: lastItems,
                analyses: plan.analyses,
                duplicateGroups: plan.duplicateGroups,
                exportTargets: lastExportTargets ?? [],
                operation: plan.operation
            )
            // 保留用户对单个操作的启用/禁用选择。
            for i in newPlan.operations.indices {
                if let previous = enabledBySource[newPlan.operations[i].source] {
                    newPlan.operations[i].isEnabled = previous
                }
            }
            self.plan = newPlan
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func execute(plan: OrganizationPlan, taskName: String, operation: CopyOrMove? = nil) async {
        let effectiveOperation = operation ?? plan.operation
        do {
            let enabledCount = plan.operations.filter(\.isEnabled).count
            let record = try await Organizer().execute(plan: plan, taskName: taskName, operation: effectiveOperation)
            try await RollbackService().save(record: record)
            self.plan = nil
            successMessage = "整理完成，已处理 \(record.moves.count) 个文件（启用 \(enabledCount) 项）"
        } catch let error as OrganizerError {
            // 即使整理中途失败，也要保存已完成操作的记录以便部分回滚。
            try? await RollbackService().save(record: error.partialRecord)
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
