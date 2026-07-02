import Foundation

/// 一次完整分析的输入参数（同时充当重建计划所需的上下文快照）。
struct AnalysisRequest: Sendable {
    let folders: [URL]
    let taskID: UUID?
    let template: NamingTemplate
    let destination: URL
    let operation: CopyOrMove
    let exportTargets: [ExportTarget]
    /// 云端增强配置；为 nil 表示本次分析不启用云端增强。
    let cloudConfig: CloudConfiguration?
}

/// 分析各阶段的进度事件，供 UI 展示。
enum AnalysisProgress: Sendable {
    case scanning
    case analyzing(completed: Int, total: Int)
    case enhancing(completed: Int, total: Int)
    case detectingDuplicates
    case buildingPlan

    /// 面向用户的中文阶段文案。
    var label: String {
        switch self {
        case .scanning:
            return "正在扫描文件…"
        case .analyzing(let completed, let total):
            return "本地分析中 \(completed)/\(total)"
        case .enhancing(let completed, let total):
            return "云端增强中 \(completed)/\(total)"
        case .detectingDuplicates:
            return "正在检测重复文件…"
        case .buildingPlan:
            return "正在生成整理计划…"
        }
    }
}

/// 分析结果：整理计划 + 各类非致命告警计数。
struct AnalysisOutcome: Sendable {
    let plan: OrganizationPlan
    /// 扫描得到的文件列表，供调整重复保留项后重建计划使用。
    let items: [FileItem]
    let inaccessibleDirectoryCount: Int
    let analysisFailureCount: Int
    let hashFailureCount: Int
    let cloudFailureCount: Int
}

/// 编排「扫描 → 本地分析 → 云端增强 → 去重 → 建计划」的完整分析流水线。
///
/// 自身无隔离状态，并发都发生在内部 TaskGroup 中；取消通过
/// `Task.checkCancellation()` 以 `CancellationError` 抛出，由调用方决定如何呈现。
struct AnalysisPipeline: Sendable {
    let scanner: FileScanner
    let localAnalyzer: LocalAnalyzer
    let duplicateDetector: DuplicateDetector

    init(
        scanner: FileScanner = FileScanner(),
        localAnalyzer: LocalAnalyzer = LocalAnalyzer(),
        duplicateDetector: DuplicateDetector = DuplicateDetector()
    ) {
        self.scanner = scanner
        self.localAnalyzer = localAnalyzer
        self.duplicateDetector = duplicateDetector
    }

    func run(
        _ request: AnalysisRequest,
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> AnalysisOutcome {
        onProgress(.scanning)
        let scanResult = await scanner.scan(folders: request.folders)
        try Task.checkCancellation()
        let items = scanResult.items

        let (analyses, textsByID, analysisFailureCount) = try await analyzeLocally(items: items, onProgress: onProgress)
        try Task.checkCancellation()

        var enhancedAnalyses = analyses
        var cloudFailureCount = 0
        if let config = request.cloudConfig {
            (enhancedAnalyses, cloudFailureCount) = try await enhanceWithCloud(
                analyses: analyses,
                textsByID: textsByID,
                config: config,
                onProgress: onProgress
            )
        }
        try Task.checkCancellation()

        onProgress(.detectingDuplicates)
        let detectionResult = await duplicateDetector.detectDuplicates(in: items)
        try Task.checkCancellation()

        onProgress(.buildingPlan)
        let engine = NamingEngine(template: request.template, destination: request.destination)
        let plan = try engine.buildPlan(
            taskID: request.taskID,
            items: items,
            analyses: enhancedAnalyses,
            duplicateGroups: detectionResult.groups,
            exportTargets: request.exportTargets,
            operation: request.operation
        )

        return AnalysisOutcome(
            plan: plan,
            items: items,
            inaccessibleDirectoryCount: scanResult.inaccessibleCount,
            analysisFailureCount: analysisFailureCount,
            hashFailureCount: detectionResult.inaccessibleCount,
            cloudFailureCount: cloudFailureCount
        )
    }

    /// 并发执行本地分析；单个文件失败时回退为基于文件名的兜底结果，不中断整个批次。
    /// - Returns: 与 `items` 顺序一致的分析结果、按文件 ID 索引的提取文本、失败计数。
    private func analyzeLocally(
        items: [FileItem],
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> (analyses: [FileAnalysis], textsByID: [UUID: String], failureCount: Int) {
        var textsByID: [UUID: String] = [:]
        var collected: [FileAnalysis] = []
        var failureCount = 0
        let total = items.count
        onProgress(.analyzing(completed: 0, total: total))

        try await withThrowingTaskGroup(of: (item: FileItem, text: String, analysis: FileAnalysis, failed: Bool).self) { group in
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

            for try await result in group {
                try Task.checkCancellation()
                textsByID[result.item.id] = result.text
                collected.append(result.analysis)
                if result.failed {
                    failureCount += 1
                }
                onProgress(.analyzing(completed: collected.count, total: total))
            }
        }

        // 保持 analyses 与 items 顺序一致，便于后续计划构建。
        let analysisByID = Dictionary(uniqueKeysWithValues: collected.map { ($0.id, $0) })
        let ordered = items.compactMap { analysisByID[$0.id] }
        return (ordered, textsByID, failureCount)
    }

    /// 调用云端大模型增强本地分析结果；单个文件失败时保留本地结果并计数。
    /// 云端请求限速：最多 3 个并发，避免触发服务商速率限制。
    private func enhanceWithCloud(
        analyses: [FileAnalysis],
        textsByID: [UUID: String],
        config: CloudConfiguration,
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> (analyses: [FileAnalysis], failureCount: Int) {
        let cloudAnalyzer = CloudAnalyzer(baseURL: config.baseURL, apiKey: config.apiKey, model: config.model)
        let maxConcurrentCloud = 3
        let total = analyses.count
        var result = analyses
        var failureCount = 0
        var completed = 0
        onProgress(.enhancing(completed: 0, total: total))

        var index = 0
        while index < total {
            try Task.checkCancellation()
            let batchEnd = min(index + maxConcurrentCloud, total)
            let batchEntries = Array(index..<batchEnd).map { (
                index: $0,
                analysis: result[$0],
                text: textsByID[result[$0].id] ?? ""
            ) }
            let batchResults: [(index: Int, analysis: FileAnalysis, succeeded: Bool)] = await withTaskGroup(of: (Int, FileAnalysis, Bool).self) { group in
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
                for await item in group {
                    collected.append(item)
                }
                return collected
            }
            for batchResult in batchResults {
                result[batchResult.index] = batchResult.analysis
                if !batchResult.succeeded {
                    failureCount += 1
                }
                completed += 1
                onProgress(.enhancing(completed: completed, total: total))
            }
            index = batchEnd
        }

        return (result, failureCount)
    }
}
