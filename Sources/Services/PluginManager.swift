import Foundation

actor PluginManager {
    private let plugins: [any ExportPlugin] = [DEVONthinkPlugin()]

    func export(file: URL, target: ExportTarget) async throws -> FileOperationRecord.Export {
        guard let plugin = plugins.first(where: { $0.canHandle(target: target) }) else {
            throw AnalysisError.unsupportedType("No plugin for \(target)")
        }
        let details = try await plugin.export(file: file, target: target)
        return FileOperationRecord.Export(pluginID: plugin.id, details: details)
    }

    func pluginID(for target: ExportTarget) -> String? {
        plugins.first { $0.canHandle(target: target) }?.id
    }
}
