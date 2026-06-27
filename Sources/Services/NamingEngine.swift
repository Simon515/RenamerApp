import Foundation

struct NamingEngine {
    let template: NamingTemplate
    let destination: URL

    func buildPlan(
        taskID: UUID?,
        items: [FileItem],
        analyses: [FileAnalysis],
        duplicateGroups: [DuplicateGroup],
        exportTargets: [ExportTarget] = [],
        operation: CopyOrMove = .copy
    ) throws -> OrganizationPlan {
        let analysisByID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.id, $0) })
        var operations: [PlanOperation] = []
        var usedNamesByDirectory: [String: Set<String>] = [:]

        let skippedIDs = Set(duplicateGroups.flatMap { group -> [UUID] in
            guard let keep = group.keepIndex else { return [] }
            return group.items.enumerated().compactMap { $0.offset == keep ? nil : $0.element.id }
        })

        for item in items where !skippedIDs.contains(item.id) {
            guard let analysis = analysisByID[item.id] else { continue }
            let folder = resolve(template.folderTemplate, analysis: analysis)
            let baseName = resolve(template.fileNameTemplate, analysis: analysis)
            let destDir = destination.appending(path: folder)
            let dirKey = destDir.path()
            let uniqueName = uniqueFileName(base: baseName, ext: item.pathExtension, used: &usedNamesByDirectory[dirKey, default: Set()])
            let dest = destDir.appending(path: uniqueName)
            operations.append(PlanOperation(id: UUID(), source: item.url, destination: dest, exportTargets: exportTargets, isEnabled: true))
        }

        return OrganizationPlan(id: UUID(), taskID: taskID, analyses: analyses, operations: operations, duplicateGroups: duplicateGroups, operation: operation)
    }

    private func resolve(_ template: String, analysis: FileAnalysis) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{title}", with: sanitize(analysis.title ?? "Untitled"))
        result = result.replacingOccurrences(of: "{category}", with: sanitize(analysis.category ?? "Uncategorized"))
        result = result.replacingOccurrences(of: "{source}", with: sanitize(analysis.source ?? "Unknown"))

        // 先处理带自定义格式的日期令牌 {date:<format>}。
        result = resolveDateTokens(in: result, date: analysis.date)

        // 处理默认日期令牌 {date}。
        if let date = analysis.date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            result = result.replacingOccurrences(of: "{date}", with: sanitize(fmt.string(from: date)))
        } else {
            result = result.replacingOccurrences(of: "{date}", with: "nodate")
        }
        return result
    }

    /// 解析并替换 `{date:<format>}` 令牌；格式无效时回退到 `yyyyMMdd`。
    private func resolveDateTokens(in template: String, date: Date?) -> String {
        let pattern = #"\{date:([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return template }
        let nsRange = NSRange(template.startIndex..., in: template)

        var matches: [(range: Range<String.Index>, format: String)] = []
        regex.enumerateMatches(in: template, options: [], range: nsRange) { match, _, _ in
            guard let match = match,
                  let fullRange = Range(match.range, in: template),
                  let formatRange = Range(match.range(at: 1), in: template) else { return }
            matches.append((fullRange, String(template[formatRange])))
        }

        var result = template
        // 从后往前替换，避免前面的替换影响后续 range。
        for (range, format) in matches.reversed() {
            let replacement: String
            if let date = date {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                let formatted = sanitize(formatter.string(from: date))
                replacement = formatted.isEmpty ? fallbackDateString(for: date) : formatted
            } else {
                replacement = "nodate"
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func fallbackDateString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        return fmt.string(from: date)
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
