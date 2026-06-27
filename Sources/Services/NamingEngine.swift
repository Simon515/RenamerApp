import Foundation

struct NamingEngine {
    let template: NamingTemplate
    let destination: URL

    func buildPlan(
        taskID: UUID?,
        items: [FileItem],
        analyses: [FileAnalysis],
        duplicateGroups: [DuplicateGroup]
    ) throws -> OrganizationPlan {
        let analysisByID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.id, $0) })
        var operations: [PlanOperation] = []
        var usedNames: Set<String> = []

        let skippedIDs = Set(duplicateGroups.flatMap { group -> [UUID] in
            guard let keep = group.keepIndex else { return [] }
            return group.items.enumerated().compactMap { $0.offset == keep ? nil : $0.element.id }
        })

        for item in items where !skippedIDs.contains(item.id) {
            guard let analysis = analysisByID[item.id] else { continue }
            let folder = resolve(template.folderTemplate, analysis: analysis)
            let baseName = resolve(template.fileNameTemplate, analysis: analysis)
            let uniqueName = uniqueFileName(base: baseName, ext: item.pathExtension, used: &usedNames)
            let dest = destination.appending(path: folder).appending(path: uniqueName)
            operations.append(PlanOperation(id: UUID(), source: item.url, destination: dest, exportTargets: [], isEnabled: true))
        }

        return OrganizationPlan(id: UUID(), taskID: taskID, analyses: analyses, operations: operations, duplicateGroups: duplicateGroups)
    }

    private func resolve(_ template: String, analysis: FileAnalysis) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{title}", with: sanitize(analysis.title ?? "Untitled"))
        result = result.replacingOccurrences(of: "{category}", with: sanitize(analysis.category ?? "Uncategorized"))
        result = result.replacingOccurrences(of: "{source}", with: sanitize(analysis.source ?? "Unknown"))
        if let date = analysis.date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            result = result.replacingOccurrences(of: "{date}", with: fmt.string(from: date))
        } else {
            result = result.replacingOccurrences(of: "{date}", with: "nodate")
        }
        return result
    }

    private func sanitize(_ string: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:?%*|\"<>")
        return string.components(separatedBy: invalid).joined(separator: "_")
    }

    private func uniqueFileName(base: String, ext: String, used: inout Set<String>) -> String {
        let full = ext.isEmpty ? base : "\(base).\(ext)"
        if used.insert(full).inserted { return full }
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(String(format: "%02d", counter))" : "\(base)_\(String(format: "%02d", counter)).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            counter += 1
        }
    }
}
