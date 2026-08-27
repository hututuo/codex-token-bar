import Foundation

enum QuotaHistoryWindowKind: String, CaseIterable, Hashable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
}

enum QuotaHistoryCyclePolicy {
    static let resetJitterTolerance: TimeInterval = 5
    static let newCycleResetDelta: TimeInterval = 5 * 60
    static let stableBandDuration: TimeInterval = 5 * 60
    static let maintenanceInterval: TimeInterval = 24 * 60 * 60

    /// A reset is an observation, not a timer. Full quota is required only on
    /// the boundary sample; it never has to remain full for five minutes.
    static func startsNewCycle(
        currentUsedPercent: Int?,
        currentResetsAt: Date?,
        acceptedResetsAt: Date?
    ) -> Bool {
        guard currentUsedPercent.map(clampedPercent) == 0,
              let currentResetsAt,
              let acceptedResetsAt else { return false }
        return abs(currentResetsAt.timeIntervalSince(acceptedResetsAt)) > newCycleResetDelta
    }

    static func resetDelta(_ lhs: Date?, _ rhs: Date?) -> TimeInterval? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs.timeIntervalSince(rhs))
    }

    static func isResetJitter(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            (resetDelta(lhs, rhs) ?? .infinity) <= resetJitterTolerance
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

/// Tracks only successful quota observations. It performs O(1) work and does
/// not own a timer, network request, or system wakeup.
struct QuotaResetStabilityCandidate: Equatable, Sendable {
    private(set) var firstObservedAt: Date
    private(set) var lastObservedAt: Date
    private(set) var minimumResetsAt: Date
    private(set) var maximumResetsAt: Date
    private(set) var sampleCount: Int

    init(observedAt: Date, resetsAt: Date) {
        firstObservedAt = observedAt
        lastObservedAt = observedAt
        minimumResetsAt = resetsAt
        maximumResetsAt = resetsAt
        sampleCount = 1
    }

    /// Returns true only after at least two successful samples cover five real
    /// minutes while the whole reset band remains no wider than five seconds.
    mutating func observe(observedAt: Date, resetsAt: Date) -> Bool {
        guard observedAt >= lastObservedAt else { return false }
        let nextMinimum = min(minimumResetsAt, resetsAt)
        let nextMaximum = max(maximumResetsAt, resetsAt)
        if nextMaximum.timeIntervalSince(nextMinimum) > QuotaHistoryCyclePolicy.resetJitterTolerance {
            self = QuotaResetStabilityCandidate(observedAt: observedAt, resetsAt: resetsAt)
            return false
        }
        minimumResetsAt = nextMinimum
        maximumResetsAt = nextMaximum
        lastObservedAt = observedAt
        sampleCount += 1
        return sampleCount >= 2
            && lastObservedAt.timeIntervalSince(firstObservedAt) >= QuotaHistoryCyclePolicy.stableBandDuration
    }
}
