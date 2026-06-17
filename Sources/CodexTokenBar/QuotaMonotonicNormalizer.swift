import Foundation

/// Codex records quota snapshots on completed model responses. When several
/// sessions are active, an older request can finish after a newer request and
/// publish an older rate-limit snapshot with a later log timestamp. Within the
/// same reset window, the newest observed used percent is the trustworthy
/// display/history value; a reset timestamp change starts a fresh cycle.
enum QuotaMonotonicNormalizer {
    private static let resetGraceInterval: TimeInterval = 2 * 60

    static func normalizedSnapshot(_ current: AccountQuotaSnapshot, after previous: AccountQuotaSnapshot?) -> AccountQuotaSnapshot {
        guard let previous, sameAccount(current, previous) else { return current }

        var adjusted = current
        adjusted.fiveHour = normalizedWindow(current.fiveHour, after: previous.fiveHour)
        adjusted.sevenDay = normalizedWindow(current.sevenDay, after: previous.sevenDay)
        return adjusted
    }

    static func normalizedUsedPercent(
        currentUsedPercent: Int?,
        currentResetsAt: Date?,
        previousUsedPercent: Int?,
        previousResetsAt: Date?
    ) -> Int? {
        guard let currentUsedPercent else { return nil }
        let current = clampedPercent(currentUsedPercent)
        guard let previousUsedPercent else { return current }
        let previous = clampedPercent(previousUsedPercent)

        guard current < previous else { return current }
        if isSameObservedCycle(currentResetsAt: currentResetsAt, previousResetsAt: previousResetsAt) {
            return previous
        }
        return current
    }

    private static func normalizedWindow(
        _ current: AccountQuotaWindow?,
        after previous: AccountQuotaWindow?
    ) -> AccountQuotaWindow? {
        guard let current else { return nil }
        let used = normalizedUsedPercent(
            currentUsedPercent: current.usedPercent,
            currentResetsAt: current.resetsAt,
            previousUsedPercent: previous?.usedPercent,
            previousResetsAt: previous?.resetsAt
        ) ?? current.usedPercent

        guard used != current.usedPercent else { return current }
        return AccountQuotaWindow(label: current.label, usedPercent: used, resetsAt: current.resetsAt)
    }

    private static func sameAccount(_ lhs: AccountQuotaSnapshot, _ rhs: AccountQuotaSnapshot) -> Bool {
        identityParts(lhs) == identityParts(rhs)
    }

    private static func identityParts(_ snapshot: AccountQuotaSnapshot) -> [String] {
        [snapshot.accountName, snapshot.planType, snapshot.limitName]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    private static func clampedPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private static func isSameObservedCycle(currentResetsAt: Date?, previousResetsAt: Date?) -> Bool {
        switch (currentResetsAt, previousResetsAt) {
        case let (current?, previous?):
            return abs(current.timeIntervalSince(previous)) <= resetGraceInterval
        case (nil, nil):
            return true
        case (_?, nil), (nil, _?):
            return false
        }
    }
}
