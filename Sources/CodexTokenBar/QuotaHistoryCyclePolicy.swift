import Foundation

enum QuotaHistoryWindowKind: String, CaseIterable, Hashable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
}

enum QuotaHistoryCyclePolicy {
    static let maintenanceInterval: TimeInterval = 24 * 60 * 60
    /// Covers Date/Unix REAL round-trip residue without weakening any
    /// server-visible whole-second boundary.
    static let timestampComparisonTolerance: TimeInterval = 0.000_001

    /// A forward server boundary confirms the cycle regardless of how much
    /// quota has already been consumed before the first observation.
    static func startsNewCycle(
        currentUsedPercent: Int?,
        currentResetsAt: Date?,
        acceptedResetsAt: Date?,
        window: QuotaHistoryWindowKind = .fiveHour
    ) -> Bool {
        let policy = QuotaHistoryProtectionPolicy.policy(for: window)
        guard let currentUsedPercent, (0...policy.maximumNewCycleUsedPercent).contains(currentUsedPercent),
              let currentResetsAt,
              let acceptedResetsAt else { return false }
        return currentResetsAt.timeIntervalSince(acceptedResetsAt)
            > policy.newCycleResetDelta + timestampComparisonTolerance
    }

    static func resetDelta(_ lhs: Date?, _ rhs: Date?) -> TimeInterval? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs.timeIntervalSince(rhs))
    }

    static func isResetJitter(_ lhs: Date?, _ rhs: Date?, window: QuotaHistoryWindowKind = .fiveHour) -> Bool {
        let tolerance = QuotaHistoryProtectionPolicy.policy(for: window).resetJitterTolerance
        return switch (lhs, rhs) {
        case let (lhs?, rhs?):
            (resetDelta(lhs, rhs) ?? .infinity)
                <= tolerance + timestampComparisonTolerance
        case (nil, nil):
            true
        case (_?, nil), (nil, _?):
            false
        }
    }

    static func clampedPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
