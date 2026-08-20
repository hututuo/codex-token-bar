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
    private var stateDatabasePath: String?

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
        let nextStateDatabasePath = dataSource?.stateDatabase.standardizedFileURL.path
        let result: DashboardSourceTransitionResult
        if !hasBoundSource || sourceIdentity != nextIdentity {
            result = .identityTransition
        } else if sourcePath != nextPath {
            result = .pathRebind
        } else {
            return .noChange
        }

        hasBoundSource = true
        if let stateDatabasePath,
           stateDatabasePath != nextStateDatabasePath {
            CodexStateDatabaseReadPool.shared.close(
                url: URL(fileURLWithPath: stateDatabasePath)
            )
        }
        sourceIdentity = nextIdentity
        sourcePath = nextPath
        stateDatabasePath = nextStateDatabasePath
        usageStore.setDataSource(dataSource)
        quotaStore.setDataSource(dataSource)
        liveMonitor.setDataSource(dataSource)
        taskCompletionMonitor.bind(dataSource: dataSource)
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
