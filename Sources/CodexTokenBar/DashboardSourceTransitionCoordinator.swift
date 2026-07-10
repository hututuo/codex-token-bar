import Foundation

enum DashboardSourceTransitionResult: Equatable {
    case identityTransition
    case pathRebind
    case noChange
}

@MainActor
final class DashboardSourceTransitionCoordinator {
    private var hasBoundSource = false
    private var sourceIdentity: String?
    private var sourcePath: String?

    @discardableResult
    func transition(
        to dataSource: CodexDataSource?,
        usageStore: CodexUsageStore,
        quotaStore: AccountQuotaStore,
        liveMonitor: LiveRateMonitor,
        taskCompletionMonitor: TaskCompletionMonitor,
        providerSyncStore: ProviderSyncStore
    ) -> DashboardSourceTransitionResult {
        let nextIdentity = dataSource?.stableIdentityKey
        let nextPath = dataSource?.codexHome.standardizedFileURL.path
        let result: DashboardSourceTransitionResult
        if !hasBoundSource || sourceIdentity != nextIdentity {
            result = .identityTransition
        } else if sourcePath != nextPath {
            result = .pathRebind
        } else {
            return .noChange
        }

        hasBoundSource = true
        sourceIdentity = nextIdentity
        sourcePath = nextPath
        usageStore.setDataSource(dataSource)
        quotaStore.setDataSource(dataSource)
        liveMonitor.setDataSource(dataSource)
        taskCompletionMonitor.start(dataSource: dataSource)
        providerSyncStore.setDataSource(dataSource)
        switch result {
        case .identityTransition:
            quotaStore.refresh(force: true)
        case .pathRebind:
            usageStore.refresh()
            quotaStore.refresh(force: true)
        case .noChange:
            break
        }
        return result
    }
}
