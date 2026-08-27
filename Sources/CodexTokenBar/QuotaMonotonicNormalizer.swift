import Foundation

/// Codex records quota snapshots on completed model responses. When several
/// sessions are active, an older request can finish after a newer request and
/// publish an older rate-limit snapshot with a later log timestamp. Within the
/// same reset window, the newest observed used percent is the trustworthy
/// display/history value. Persisted cycle IDs are authoritative; legacy rows
/// can start a fresh cycle only through the strict reset-delta/full-quota rule.
enum QuotaMonotonicNormalizer {
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
        previousResetsAt: Date?,
        currentCycleID: String? = nil,
        previousCycleID: String? = nil
    ) -> Int? {
        guard let currentUsedPercent else { return nil }
        let current = clampedPercent(currentUsedPercent)
        guard let previousUsedPercent else { return current }
        let previous = clampedPercent(previousUsedPercent)

        guard current < previous else { return current }
        if startsNewCycle(
            currentUsedPercent: current,
            currentResetsAt: currentResetsAt,
            previousResetsAt: previousResetsAt,
            currentCycleID: currentCycleID,
            previousCycleID: previousCycleID
        ) {
            return current
        }
        if previous - current >= 20 {
            return current
        }
        return previous
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
            previousResetsAt: previous?.resetsAt,
            currentCycleID: current.cycleID,
            previousCycleID: previous?.cycleID
        ) ?? current.usedPercent

        guard used != current.usedPercent else { return current }
        return AccountQuotaWindow(
            label: current.label,
            usedPercent: used,
            resetsAt: current.resetsAt,
            cycleID: current.cycleID
        )
    }

    private static func sameAccount(_ lhs: AccountQuotaSnapshot, _ rhs: AccountQuotaSnapshot) -> Bool {
        switch (lhs.historyIdentity, rhs.historyIdentity) {
        case let (lhsIdentity?, rhsIdentity?):
            return lhsIdentity == rhsIdentity
        case (nil, nil):
            return identityParts(lhs) == identityParts(rhs)
        case (_?, nil), (nil, _?):
            return false
        }
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

    private static func startsNewCycle(
        currentUsedPercent: Int,
        currentResetsAt: Date?,
        previousResetsAt: Date?,
        currentCycleID: String?,
        previousCycleID: String?
    ) -> Bool {
        let currentID = nonempty(currentCycleID)
        let previousID = nonempty(previousCycleID)
        if let currentID, let previousID {
            return currentID != previousID
        }
        // Introducing an ID for legacy state, or temporarily missing one, is
        // not itself a reset. Use the same strict fallback as history replay.
        return QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: currentUsedPercent,
            currentResetsAt: currentResetsAt,
            acceptedResetsAt: previousResetsAt
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
