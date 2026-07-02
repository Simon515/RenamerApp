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

    private let pipeline = AnalysisPipeline()

    // 保留最近一次分析的请求与文件列表，以便在重复文件保留选择变化时重建计划。
    private var lastRequest: AnalysisRequest?
    private var lastItems: [FileItem]?

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL, operation: CopyOrMove = .copy) async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        let request = AnalysisRequest(
            folders: folders,
            taskID: task?.id,
            template: template,
            destination: destination,
            operation: task?.operation ?? operation,
            exportTargets: task?.exportTargets ?? [],
            cloudConfig: task?.useCloudAI == true ? settings?.cloudConfiguration : nil
        )

        do {
            let outcome = try await pipeline.run(request) { _ in }
            lastRequest = request
            lastItems = outcome.items
            plan = outcome.plan

            var messages: [String] = []
            if outcome.inaccessibleDirectoryCount > 0 {
                messages.append("\(outcome.inaccessibleDirectoryCount) 个目录无法访问")
            }
            if outcome.analysisFailureCount > 0 {
                messages.append("\(outcome.analysisFailureCount) 个文件无法分析")
            }
            if outcome.hashFailureCount > 0 {
                messages.append("\(outcome.hashFailureCount) 个文件无法计算哈希以检测重复")
            }
            if outcome.cloudFailureCount > 0 {
                messages.append("云端增强失败 \(outcome.cloudFailureCount) 个文件")
            }
            if !messages.isEmpty {
                errorMessage = messages.joined(separator: "\n")
            }
        } catch is CancellationError {
            // 用户取消：静默返回，不视为错误。
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 当用户在预览中调整重复文件保留项时，使用原始参数重建操作列表。
    func rebuildPlan() async {
        guard let plan,
              let lastRequest,
              let lastItems else { return }

        let engine = NamingEngine(template: lastRequest.template, destination: lastRequest.destination)
        do {
            let enabledBySource = Dictionary(uniqueKeysWithValues: plan.operations.map { ($0.source, $0.isEnabled) })
            var newPlan = try engine.buildPlan(
                taskID: plan.taskID,
                items: lastItems,
                analyses: plan.analyses,
                duplicateGroups: plan.duplicateGroups,
                exportTargets: lastRequest.exportTargets,
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
            do {
                try await RollbackService().save(record: record)
                self.plan = nil
                successMessage = "整理完成，已处理 \(record.moves.count) 个文件（启用 \(enabledCount) 项）"
            } catch {
                // 整理已成功，但回滚记录保存失败；保留计划以便用户知晓并自行处理。
                errorMessage = "整理已完成，但回滚记录保存失败：\(error.localizedDescription)"
            }
        } catch let error as OrganizerError {
            // 即使整理中途失败，也要保存已完成操作的记录以便部分回滚。
            try? await RollbackService().save(record: error.partialRecord)
            if let skipped = error.underlying as? OrganizerSkippedError {
                // 仅有“目标已存在被跳过”属于非致命情况：整理实际已完成，视为成功并附带提示。
                self.plan = nil
                successMessage = "整理完成，已处理 \(error.partialRecord.moves.count) 个文件；\(skipped.skippedCount) 个目标已存在被跳过"
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
