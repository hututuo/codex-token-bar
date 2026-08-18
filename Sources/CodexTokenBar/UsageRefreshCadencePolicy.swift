import Foundation

enum UsageRefreshCadencePolicy {
    /// The smallest aggregate bucket is five minutes and is aligned to UTC
    /// epoch time, rather than to an app launch or timer start time.
    static let fiveMinuteBoundary: TimeInterval = 5 * 60
    static let settleDelay: TimeInterval = 15

    /// Returns the UTC epoch-aligned five-minute boundary at or before `date`.
    static func utcEpochFiveMinuteBoundary(for date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        let boundary = floor(epoch / fiveMinuteBoundary) * fiveMinuteBoundary
        return Date(timeIntervalSince1970: boundary)
    }

    /// The newest bucket boundary that has had the full settle delay to close.
    static func latestEligibleBoundary(now: Date = Date()) -> Date {
        utcEpochFiveMinuteBoundary(for: now.addingTimeInterval(-settleDelay))
    }

    /// Returns the next wall-clock-aligned aggregate fire time.
    ///
    /// Every aggregate interval is an integer multiple of the five-minute
    /// epoch.  A fire is scheduled at the boundary plus the settle delay and
    /// is strictly after `date`, so a timer cannot immediately re-fire for the
    /// same boundary after waking up.
    static func nextAggregateFireDate(
        after date: Date,
        intervalMinutes: Int
    ) -> Date {
        let minutes = UsageRefreshCadenceSettings.normalizedAggregateIntervalMinutes(intervalMinutes)
        let interval = TimeInterval(minutes * 60)
        let epoch = date.timeIntervalSince1970
        let currentBoundary = floor(epoch / interval) * interval
        var candidate = currentBoundary + settleDelay
        if candidate <= epoch {
            candidate += interval
        }
        return Date(timeIntervalSince1970: candidate)
    }

    static func aggregateInterval(
        mainDashboardVisible: Bool,
        settings: UsageRefreshCadenceSettings
    ) -> TimeInterval {
        let minutes = mainDashboardVisible
            ? settings.usageVisibleAggregateIntervalMinutes
            : settings.usageBackgroundAggregateIntervalMinutes
        return TimeInterval(minutes * 60)
    }

}
