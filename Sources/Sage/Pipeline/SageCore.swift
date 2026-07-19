import Foundation

/// headless 组合根：装配监控/规则/执行/日志/队列。UI 在第 4 份计划接入。
public struct SageCore {
    public struct Assembled {
        public let coordinator: Coordinator
        public let rulesProvider: RuleStoreRulesProvider
        public let manualIntake: ManualIntake
    }

    public static func makeDefault(supportDirectory: URL, gateway: LLMGateway) -> Assembled {
        let extraction = ExtractionProvider(gateway: gateway)
        let engine = RuleEngine(provider: extraction)
        let metadataProvider = ExtractionMetadataProvider(extraction: extraction, gateway: gateway)
        let executor = LocalActionExecutor(metadataProvider: metadataProvider)
        let journal = Journal(directory: supportDirectory)
        let queue = ConfirmQueue(directory: supportDirectory)
        let store = RuleStore(directory: supportDirectory)
        let rulesProvider = RuleStoreRulesProvider(store: store)
        let coordinator = Coordinator(engine: engine, rulesProvider: rulesProvider,
                                      executor: executor, journal: journal, confirmQueue: queue)
        return Assembled(coordinator: coordinator, rulesProvider: rulesProvider,
                         manualIntake: ManualIntake())
    }
}
