import Foundation

actor PluginManager {
    private let plugins: [any ExportPlugin] = [DEVONthinkPlugin()]

    func export(file: URL, target: ExportTarget) async throws -> String {
        guard let plugin = plugins.first(where: { $0.canHandle(target: target) }) else {
            throw AnalysisError.unsupportedType("No plugin for \(target)")
        }
        return try await plugin.export(file: file, target: target)
    }
}
