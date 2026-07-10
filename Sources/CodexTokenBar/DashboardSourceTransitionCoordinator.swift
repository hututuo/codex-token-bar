import Foundation

@MainActor
final class DashboardSourceTransitionCoordinator {
    private var hasBoundSource = false
    private var sourceIdentity: String?

    @discardableResult
    func transition(
        to dataSource: CodexDataSource?,
        usageStore: CodexUsageStore,
        quotaStore: AccountQuotaStore,
        liveMonitor: LiveRateMonitor,
        taskCompletionMonitor: TaskCompletionMonitor,
        providerSyncStore: ProviderSyncStore
    ) -> Bool {
        let nextIdentity = dataSource?.stableIdentityKey
        guard !hasBoundSource || sourceIdentity != nextIdentity else {
            return false
        }

        hasBoundSource = true
        sourceIdentity = nextIdentity
        usageStore.setDataSource(dataSource)
        quotaStore.setDataSource(dataSource)
        liveMonitor.setDataSource(dataSource)
        taskCompletionMonitor.start(dataSource: dataSource)
        providerSyncStore.setDataSource(dataSource)
        quotaStore.refresh(force: true)
        return true
    }
}
