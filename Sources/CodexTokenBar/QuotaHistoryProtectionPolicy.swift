import Foundation

/// Separate policy values let the short window be relaxed independently of
/// the slower weekly window. The first release intentionally uses equal values.
struct QuotaHistoryProtectionPolicy: Equatable, Sendable {
    let newCycleResetDelta: TimeInterval
    let maximumNewCycleUsedPercent: Int
    let resetJitterTolerance: TimeInterval
    let correctionSampleCount: Int
    let correctionEvidenceDuration: TimeInterval

    static let fiveHour = Self(
        newCycleResetDelta: 1_800, maximumNewCycleUsedPercent: 100,
        resetJitterTolerance: 5, correctionSampleCount: 3, correctionEvidenceDuration: 300
    )
    static let sevenDay = Self(
        newCycleResetDelta: 1_800, maximumNewCycleUsedPercent: 100,
        resetJitterTolerance: 5, correctionSampleCount: 3, correctionEvidenceDuration: 300
    )

    static func policy(for window: QuotaHistoryWindowKind) -> Self {
        switch window {
        case .fiveHour: .fiveHour
        case .sevenDay: .sevenDay
        }
    }
}
