import Foundation

struct UsageRefreshCadenceDecision: Equatable {
    let interval: TimeInterval
    let recoveryDelay: TimeInterval?
    let isActive: Bool
}

enum UsageRefreshCadencePolicy {
    static let activeInterval: TimeInterval = 30
    static let visibleDashboardInterval: TimeInterval = 180
    static let compactOnlyInterval: TimeInterval = 300

    private static let minimumActiveRate: Double = 0.05
    private static let recoveryDelayPadding: TimeInterval = 0.25

    static func decision(
        snapshot: LiveRateSnapshot,
        onlyCompactSurfaceVisible: Bool,
        now: Date = Date()
    ) -> UsageRefreshCadenceDecision {
        let baselineInterval = onlyCompactSurfaceVisible ? compactOnlyInterval : visibleDashboardInterval
        let age = max(0, now.timeIntervalSince(snapshot.updatedAt))
        let isActive = snapshot.rollingTokensPerSecond > minimumActiveRate && age < activeInterval

        guard isActive else {
            return UsageRefreshCadenceDecision(
                interval: baselineInterval,
                recoveryDelay: nil,
                isActive: false
            )
        }

        return UsageRefreshCadenceDecision(
            interval: activeInterval,
            recoveryDelay: max(0.1, activeInterval - age + recoveryDelayPadding),
            isActive: true
        )
    }
}
