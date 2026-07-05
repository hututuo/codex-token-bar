import Foundation

enum DashboardRefreshTrigger: Equatable {
    case manual
    case systemWake

    var traceName: String {
        switch self {
        case .manual:
            "dashboard.manualRefresh"
        case .systemWake:
            "dashboard.systemWakeRefresh"
        }
    }

    var traceValue: String {
        switch self {
        case .manual:
            "manual"
        case .systemWake:
            "systemWake"
        }
    }
}

enum DashboardRefreshAction: Equatable {
    case refreshUsage
    case refreshQuota(force: Bool)
    case refreshRadar
    case scanProviders
    case reloadQuotaHistoryTimeline
}

struct DashboardRefreshPlan: Equatable {
    let trigger: DashboardRefreshTrigger
    let actions: [DashboardRefreshAction]

    static func make(
        trigger: DashboardRefreshTrigger,
        providerSyncVisible: Bool
    ) -> DashboardRefreshPlan {
        var actions: [DashboardRefreshAction] = [
            .refreshUsage,
            .refreshQuota(force: true),
            .refreshRadar
        ]
        if providerSyncVisible {
            actions.append(.scanProviders)
        }
        return DashboardRefreshPlan(trigger: trigger, actions: actions)
    }
}
