import Foundation

/// Completed-body averages change only when samples change, a future timestamp
/// enters the window, or an existing sample leaves it. No one-second history scan.
enum BodySpeedSummarySchedule {
    private static let windows: [Double] = [300, 900, 1800, 604800]
    static func nextChange(samples: [ObservedSpeedSample], now: Double) -> Double {
        guard now.isFinite else { return .infinity }
        var next = Double.infinity
        for sample in samples where sample.isBody && sample.endedAt.isFinite {
            if sample.endedAt > now { next = min(next, sample.endedAt) }
            for seconds in windows {
                // Inclusion is >= cutoff, so removal is strictly after the boundary.
                let expiration = (sample.endedAt + seconds).nextUp
                if expiration > now { next = min(next, expiration) }
            }
        }
        return next
    }
    static func isDue(now: Double, lastUpdatedAt: Double, nextChangeAt: Double, samplesChanged: Bool) -> Bool {
        samplesChanged || lastUpdatedAt == 0 || now < lastUpdatedAt || now >= nextChangeAt
    }
}
