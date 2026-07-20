import Foundation
import Observation

/// 顶层应用模型：装配 SageCore 与子 ViewModel，承载全局状态。
@MainActor
@Observable
public final class AppModel {
    public struct ActivityEntry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let text: String
        public init(id: UUID = UUID(), timestamp: Date = Date(), text: String) {
            self.id = id; self.timestamp = timestamp; self.text = text
        }
    }

    public var settings: SageSettings
    public private(set) var pendingCount: Int = 0
    public private(set) var recentActivity: [ActivityEntry] = []
    public var errorMessage: String?
    /// 非错误的提示信息（与 errorMessage 分开，避免互相覆盖）。
    public var infoMessage: String?
    /// DEVONthink 是否可用（仅在有 DT 监控组时更新；未运行 → 菜单栏提示，spec §5）。
    public private(set) var dtAvailable: Bool = true

    public let ruleList: RuleListModel
    public let confirmQueue: ConfirmQueueModel
    public let journal: JournalModel

    /// 规则编辑器试运行用的引擎：复用同一 gateway 的真实提取/LLM 求值。
    public let dryRunEngine: RuleEngine

    private let coordinator: Coordinator
    private let manualIntake: ManualIntake
    private let queue: ConfirmQueue
    private let settingsStore: SettingsStore
    private let keychain: SageKeychainStore
    private let supervisor: WatcherSupervisor

    public init(supportDirectory: URL, settings: SageSettings, gateway: LLMGateway,
                keychain: SageKeychainStore) {
        self.settings = settings
        self.keychain = keychain
        self.settingsStore = SettingsStore(directory: supportDirectory)

        let assembled = SageCore.makeDefault(supportDirectory: supportDirectory, gateway: gateway)
        self.coordinator = assembled.coordinator
        self.manualIntake = assembled.manualIntake
        let store = RuleStore(directory: supportDirectory)
        self.queue = ConfirmQueue(directory: supportDirectory)
        // UI 侧 Journal 兄弟实例也要能回滚 DT 操作
        let journalActor = Journal(directory: supportDirectory, dtReverter: DTActions())

        self.ruleList = RuleListModel(store: store)
        self.confirmQueue = ConfirmQueueModel(queue: queue, coordinator: coordinator)
        self.journal = JournalModel(journal: journalActor)
        self.supervisor = WatcherSupervisor(coordinator: coordinator)
        self.dryRunEngine = RuleEngine(provider: ExtractionProvider(gateway: gateway))
    }

    public static func bootstrap(supportDirectory: URL) async -> AppModel {
        let settingsStore = SettingsStore(directory: supportDirectory)
        let settings = (try? await settingsStore.load()) ?? .defaults
        let keychain = SageKeychainStore()
        let apiKey = (try? keychain.read(account: "llm-api-key")) ?? nil
        let gateway = Self.makeGateway(settings: settings, apiKey: apiKey ?? "")
        let model = AppModel(supportDirectory: supportDirectory, settings: settings, gateway: gateway, keychain: keychain)
        await model.wireDTAvailability()
        await model.startInitialMonitoringIfEnabled()
        return model
    }

    /// 把 DT 可用性变化接到 UI 状态（bootstrap 后调用，避免 init 内 self 逃逸）。
    public func wireDTAvailability() async {
        await supervisor.setDTAvailabilityHandler { [weak self] available in
            await MainActor.run { self?.markDTAvailability(available) }
        }
    }

    public func markDTAvailability(_ available: Bool) { dtAvailable = available }

    /// 启动时若监控开关为开，则按当前规则启动 watcher（否则自动规则永不生效直到手动切换）。
    public func startInitialMonitoringIfEnabled() async {
        guard settings.monitoringEnabled else { return }
        let rules = await ruleList.currentRulesSnapshot()
        await supervisor.restart(rules: rules)
    }

    private static func makeGateway(settings: SageSettings, apiKey: String) -> LLMGateway {
        let config = LLMGatewayConfig(budget: LLMBudget(dailyLimit: settings.dailyLLMBudget, date: Date()))
        if settings.provider.enabled, let url = URL(string: settings.provider.baseURL), !apiKey.isEmpty {
            let provider = HTTPLLMProvider(config: HTTPLLMConfig(
                baseURL: url, apiKey: apiKey, model: settings.provider.model,
                timeout: settings.provider.timeoutSeconds))
            return LLMGateway(provider: provider, config: config)
        }
        // 未配置时用一个永远失败降级的占位 provider（引擎会把 LLM 条件视为不匹配）
        return LLMGateway(provider: DisabledLLMProvider(), config: config)
    }

    public func refreshQueueBadge() async {
        pendingCount = (try? await queue.count()) ?? 0
    }

    public func handleManualDrop(paths: [String]) async {
        let events = manualIntake.events(forDroppedPaths: paths)
        for event in events {
            let outcomes = await coordinator.handle(event)
            for outcome in outcomes { pushActivity(Self.activityText(for: outcome)) }
        }
        await refreshQueueBadge()
        await confirmQueue.reload()
        await journal.reload()
    }

    public func setMonitoring(_ on: Bool) async {
        settings.monitoringEnabled = on
        await persistSettings()
        await reconcileMonitoring()
    }

    /// 按当前 settings.monitoringEnabled 启停 watcher。
    private func reconcileMonitoring() async {
        let rules = await ruleList.currentRulesSnapshot()
        if settings.monitoringEnabled { await supervisor.restart(rules: rules) }
        else { await supervisor.stopAll() }
    }

    public func applySettings(_ new: SageSettings, apiKey: String?) async {
        let monitoringChanged = new.monitoringEnabled != settings.monitoringEnabled
        let launchChanged = new.launchAtLogin != settings.launchAtLogin
        settings = new
        errorMessage = nil
        infoMessage = nil

        if let apiKey {
            do { try keychain.write(account: "llm-api-key", value: apiKey) }
            catch {
                errorMessage = "API Key 写入 Keychain 失败：\(error.localizedDescription)"
                return
            }
        }
        do { try await settingsStore.save(settings) }
        catch {
            errorMessage = "设置保存失败：\(error.localizedDescription)"
            return
        }
        if launchChanged { LaunchAtLogin.set(new.launchAtLogin) }
        if monitoringChanged { await reconcileMonitoring() }
        infoMessage = "LLM 端点/密钥变更将在下次启动后完全生效。"
    }

    private func persistSettings() async {
        do { try await settingsStore.save(settings); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func pushActivity(_ text: String) {
        recentActivity.insert(ActivityEntry(text: text), at: 0)
        if recentActivity.count > 10 { recentActivity.removeLast(recentActivity.count - 10) }
    }

    public nonisolated static func activityText(for outcome: ActionOutcome) -> String {
        switch outcome {
        case .executed(let r): return "已执行「\(r.ruleName)」：\(r.sourceDescription)"
        case .enqueued(let item): return "待确认：\(ConfirmQueueModel.summary(item))"
        case .failed(_, let ruleName, let message): return "失败「\(ruleName)」：\(message)"
        case .skipped(let reason): return "跳过：\(reason)"
        }
    }
}

/// 未配置 LLM 时的占位 provider：任何调用都抛错，触发引擎降级。
struct DisabledLLMProvider: LLMProvider {
    func send(_ request: LLMRequest) async throws -> LLMResponse {
        throw LLMProviderError.emptyContent
    }
}
