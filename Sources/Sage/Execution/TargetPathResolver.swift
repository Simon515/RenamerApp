import Foundation

/// 目标路径解析：模板求值 → 拼目录 → 补扩展名 → 防重名。
public struct TargetPathResolver: Sendable {
    private let templateResolver: TemplateResolver
    private let fileExists: @Sendable (String) -> Bool

    public init(templateResolver: TemplateResolver = TemplateResolver(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.templateResolver = templateResolver
        self.fileExists = fileExists
    }

    public func resolveDestination(baseDirectory: String, template: String,
                                   sourceName: String, metadata: ExtractedMetadata) -> String {
        let (stem, ext) = splitExtension(sourceName)
        let resolved = templateResolver.resolve(template, metadata: metadata, fallbackName: stem)
        let named = appendExtension(resolved, ext: ext)
        let full = (baseDirectory as NSString).appendingPathComponent(named)
        return deduplicate(full)
    }

    public func resolveRename(inDirectoryOf sourcePath: String, template: String,
                              metadata: ExtractedMetadata) -> String {
        let dir = (sourcePath as NSString).deletingLastPathComponent
        let sourceName = (sourcePath as NSString).lastPathComponent
        return resolveDestination(baseDirectory: dir, template: template,
                                  sourceName: sourceName, metadata: metadata)
    }

    /// 拆出主干与扩展名（无扩展名时 ext 为 nil）。
    private func splitExtension(_ name: String) -> (stem: String, ext: String?) {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return (name, nil) }
        return (ns.deletingPathExtension, ext)
    }

    private func appendExtension(_ name: String, ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return name }
        return "\(name).\(ext)"
    }

    /// 已存在则在主干后加 " 2"、" 3"…（保留扩展名）。
    private func deduplicate(_ path: String) -> String {
        guard fileExists(path) else { return path }
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let fileName = ns.lastPathComponent
        let (stem, ext) = splitExtension(fileName)
        var index = 2
        while true {
            let candidateName = appendExtension("\(stem) \(index)", ext: ext)
            let candidate = (dir as NSString).appendingPathComponent(candidateName)
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }
}
