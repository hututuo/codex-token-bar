import Foundation

/// When automatic checks run (UPDATES section 3).
public enum UpdateSchedule {
    public static let launchDelay: TimeInterval = 30
    public static let interval: TimeInterval = 6 * 60 * 60

    /// The next automatic check: 30 s after launch, and never sooner than 6 h after the last successful check or the
    /// last attempt of this run. A last check stamped in the future (clock moved back) counts as now.
    public static func nextCheck(launchedAt: Date, lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Date {
        var due = launchedAt.addingTimeInterval(launchDelay)
        if let lastSuccess {
            due = max(due, min(lastSuccess, now).addingTimeInterval(interval))
        }
        if let lastAttempt {
            due = max(due, min(lastAttempt, now).addingTimeInterval(interval))
        }
        return due
    }

    /// Seconds to wait from `now` until `due`.
    public static func delay(until due: Date, now: Date) -> TimeInterval {
        max(0, due.timeIntervalSince(now))
    }

    /// Development builds (`0.0.0`) and unparseable versions only check when the user asks.
    public static func checksAutomatically(currentVersion: String) -> Bool {
        guard let version = SemanticVersion(currentVersion) else { return false }
        return !version.isDevelopment
    }
}

/// What a check result means for the user (UPDATES sections 2 and 3).
public enum UpdateOffer: Sendable, Equatable {
    case upToDate
    case available
    /// Newer, but the user chose "Skip This Version"; only a manual check offers it.
    case skipped
}

public enum UpdateDecision {
    public static func evaluate(currentVersion: String, latest: Release, skippedTag: String?, manual: Bool) -> UpdateOffer {
        guard let current = SemanticVersion(currentVersion), latest.version > current else { return .upToDate }
        if !manual, let skippedTag, skippedTag == latest.tag { return .skipped }
        return .available
    }
}
