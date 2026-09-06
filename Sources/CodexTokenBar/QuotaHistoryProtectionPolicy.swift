import Foundation

/// Independent cycle metadata thresholds. Neither threshold gates visibility;
/// 7d retrospective rejection is evaluated separately from cycle annotation.
struct QuotaHistoryProtectionPolicy: Equatable, Sendable {
    let newCycleResetDelta: TimeInterval
    let maximumNewCycleUsedPercent: Int
    let resetJitterTolerance: TimeInterval

    static let fiveHour = Self(
        newCycleResetDelta: 1_800, maximumNewCycleUsedPercent: 100,
        resetJitterTolerance: 5
    )
    static let sevenDay = Self(
        newCycleResetDelta: 900, maximumNewCycleUsedPercent: 100,
        resetJitterTolerance: 5
    )

    static func policy(for window: QuotaHistoryWindowKind) -> Self {
        switch window {
        case .fiveHour: .fiveHour
        case .sevenDay: .sevenDay
        }
    }
}
