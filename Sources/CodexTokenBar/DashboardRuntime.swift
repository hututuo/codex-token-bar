import Foundation

@MainActor
struct DashboardRuntimeComposition {
    let usageStore: CodexUsageStore
    let quotaStore: AccountQuotaStore
    let quotaHistoryStore: QuotaHistoryStore
    let radarStore: CodexRadarStore
    let providerSyncStore: ProviderSyncStore
    let taskCompletionMonitor: TaskCompletionMonitor
    let liveMonitor: LiveRateMonitor
    let sourceTransitionCoordinator: DashboardSourceTransitionCoordinator
}

@MainActor
final class DashboardRuntime: ObservableObject {
    let usageStore: CodexUsageStore
    let quotaStore: AccountQuotaStore
    let quotaHistoryStore: QuotaHistoryStore
    let radarStore: CodexRadarStore
    let providerSyncStore: ProviderSyncStore
    let taskCompletionMonitor: TaskCompletionMonitor
    let liveMonitor: LiveRateMonitor
    let sourceTransitionCoordinator: DashboardSourceTransitionCoordinator

    private let startupAction: (() -> Void)?
    private var consumers: Set<UUID> = []
    private(set) var isStarted = false

    var activeConsumerCount: Int { consumers.count }

    var composition: DashboardRuntimeComposition {
        DashboardRuntimeComposition(
            usageStore: usageStore,
            quotaStore: quotaStore,
            quotaHistoryStore: quotaHistoryStore,
            radarStore: radarStore,
            providerSyncStore: providerSyncStore,
            taskCompletionMonitor: taskCompletionMonitor,
            liveMonitor: liveMonitor,
            sourceTransitionCoordinator: sourceTransitionCoordinator
        )
    }

    init(
        usageStore: CodexUsageStore = CodexUsageStore(),
        quotaStore: AccountQuotaStore = AccountQuotaStore(),
        quotaHistoryStore: QuotaHistoryStore = QuotaHistoryStore(),
        radarStore: CodexRadarStore = CodexRadarStore(),
        providerSyncStore: ProviderSyncStore = ProviderSyncStore(),
        taskCompletionMonitor: TaskCompletionMonitor = TaskCompletionMonitor(),
        liveMonitor: LiveRateMonitor = LiveRateMonitor(),
        sourceTransitionCoordinator: DashboardSourceTransitionCoordinator = DashboardSourceTransitionCoordinator(),
        startupAction: (() -> Void)? = nil
    ) {
        self.usageStore = usageStore
        self.quotaStore = quotaStore
        self.quotaHistoryStore = quotaHistoryStore
        self.radarStore = radarStore
        self.providerSyncStore = providerSyncStore
        self.taskCompletionMonitor = taskCompletionMonitor
        self.liveMonitor = liveMonitor
        self.sourceTransitionCoordinator = sourceTransitionCoordinator
        self.startupAction = startupAction
    }

    func acquireConsumer(_ id: UUID, preciseTokenCountingEnabled: Bool = false) {
        guard consumers.insert(id).inserted else { return }
        liveMonitor.setPreciseTokenCountingEnabled(preciseTokenCountingEnabled)
        guard !isStarted else {
            if startupAction == nil {
                synchronizeSourceTransition()
            }
            return
        }
        isStarted = true
        if let startupAction {
            startupAction()
            return
        }
        quotaStore.setHistoryStore(quotaHistoryStore)
        quotaHistoryStore.start()
        synchronizeSourceTransition()
        quotaStore.start(dataSource: usageStore.currentDataSource)
        radarStore.start()
    }

    func releaseConsumer(_ id: UUID) {
        consumers.remove(id)
    }

    @discardableResult
    func synchronizeSourceTransition() -> DashboardSourceTransitionResult {
        sourceTransitionCoordinator.transition(
            to: usageStore.currentDataSource,
            usageStore: usageStore,
            quotaStore: quotaStore,
            liveMonitor: liveMonitor,
            taskCompletionMonitor: taskCompletionMonitor,
            providerSyncStore: providerSyncStore
        )
    }
}
