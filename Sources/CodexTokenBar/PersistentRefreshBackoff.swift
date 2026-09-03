import Foundation

struct PersistentRefreshBackoff: Equatable, Sendable {
    static let defaultSteps: [TimeInterval] = [1, 2, 5, 10, 30, 60]
    static let quotaSteps: [TimeInterval] = [1, 3, 5, 10, 30, 60, 120]
    static let backgroundSteps: [TimeInterval] = [1, 2, 5, 10, 30, 60, 120, 300, 600]

    private(set) var failureCount = 0
    let steps: [TimeInterval]

    init(steps: [TimeInterval] = Self.defaultSteps) {
        let normalized = steps
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        self.steps = normalized.isEmpty ? Self.defaultSteps : normalized
    }

    mutating func recordFailure(maximumDelay: TimeInterval) -> TimeInterval {
        let index = min(failureCount, steps.count - 1)
        failureCount = min(Int.max - 1, failureCount + 1)
        return min(max(0.1, maximumDelay), steps[index])
    }

    mutating func recordSuccess() {
        failureCount = 0
    }
}

struct QuotaFailureNoticePolicy: Sendable {
    static let noticeDelay: TimeInterval = 60

    static func shouldPublish(
        lastGoodAvailable: Bool,
        startedAt: Date?,
        now: Date
    ) -> Bool {
        guard lastGoodAvailable else { return true }
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= noticeDelay
    }
}
