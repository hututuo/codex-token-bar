import Foundation
import SwiftUI

/// A local-only SwiftUI timeline for the Radar countdown.
///
/// Long windows update at most once per minute. Only the final minute uses
/// second-level entries, so a many-hour announcement does not keep waking the
/// view every second.
struct CodexRadarCountdownTimelineSchedule: TimelineSchedule {
    let deadline: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let activeDeadline = deadline.flatMap { $0 > startDate ? $0 : nil }
        return Entries(
            nextDate: startDate,
            deadline: activeDeadline,
            lowFrequency: mode == .lowFrequency
        )
    }

    struct Entries: Sequence, IteratorProtocol, Sendable {
        private var nextDate: Date?
        private let deadline: Date?
        private let lowFrequency: Bool

        fileprivate init(nextDate: Date, deadline: Date?, lowFrequency: Bool) {
            self.nextDate = nextDate
            self.deadline = deadline
            self.lowFrequency = lowFrequency
        }

        mutating func next() -> Date? {
            guard let current = nextDate else {
                return nil
            }
            guard let deadline else {
                nextDate = nil
                return current
            }

            let remaining = deadline.timeIntervalSince(current)
            if remaining <= 0 {
                nextDate = nil
                return current
            }

            let interval: TimeInterval = lowFrequency || remaining > 60
                ? 60
                : 1
            nextDate = Swift.min(current.addingTimeInterval(interval), deadline)
            return current
        }
    }
}
