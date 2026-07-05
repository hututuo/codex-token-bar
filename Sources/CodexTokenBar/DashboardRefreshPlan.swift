import Foundation

enum DashboardRefreshTrigger: Equatable {
    case manual
    case systemWake
    case quotaRetry

    var traceName: String {
        switch self {
        case .manual:
            "dashboard.manualRefresh"
        case .systemWake:
            "dashboard.systemWakeRefresh"
        case .quotaRetry:
            "dashboard.quotaRetry"
        }
    }

    var traceValue: String {
        switch self {
        case .manual:
            "manual"
        case .systemWake:
            "systemWake"
        case .quotaRetry:
            "quotaRetry"
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

struct DashboardRefreshContext: Equatable {
    var providerSyncVisible: Bool
    var dashboardVisible: Bool
    var usageStale: Bool
    var radarVisible: Bool
    var radarStale: Bool

    init(
        providerSyncVisible: Bool,
        dashboardVisible: Bool = true,
        usageStale: Bool = false,
        radarVisible: Bool = true,
        radarStale: Bool = false
    ) {
        self.providerSyncVisible = providerSyncVisible
        self.dashboardVisible = dashboardVisible
        self.usageStale = usageStale
        self.radarVisible = radarVisible
        self.radarStale = radarStale
    }
}

struct DashboardRefreshPlan: Equatable {
    let trigger: DashboardRefreshTrigger
    let actions: [DashboardRefreshAction]

    static func make(
        trigger: DashboardRefreshTrigger,
        context: DashboardRefreshContext
    ) -> DashboardRefreshPlan {
        switch trigger {
        case .quotaRetry:
            return DashboardRefreshPlan(trigger: trigger, actions: [
                .refreshQuota(force: true),
                .reloadQuotaHistoryTimeline
            ])
        case .manual:
            var actions: [DashboardRefreshAction] = [
                .refreshUsage,
                .refreshQuota(force: true),
                .reloadQuotaHistoryTimeline,
                .refreshRadar
            ]
            if context.providerSyncVisible {
                actions.append(.scanProviders)
            }
            return DashboardRefreshPlan(trigger: trigger, actions: actions)
        case .systemWake:
            var actions: [DashboardRefreshAction] = []
            if context.dashboardVisible || context.usageStale {
                actions.append(.refreshUsage)
            }
            actions.append(.refreshQuota(force: true))
            actions.append(.reloadQuotaHistoryTimeline)
            if context.radarVisible || context.radarStale {
                actions.append(.refreshRadar)
            }
            return DashboardRefreshPlan(trigger: trigger, actions: actions)
        }
    }
}
