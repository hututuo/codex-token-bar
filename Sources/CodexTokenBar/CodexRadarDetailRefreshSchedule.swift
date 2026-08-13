import Foundation

enum CodexRadarDetailRefreshSchedule {
    private static let morningHour = 8
    private static let eveningHour = 18

    static func latestScheduledSlot(before date: Date, calendar: Calendar = .current) -> Date {
        if let evening = slot(on: date, hour: eveningHour, calendar: calendar),
           date >= evening {
            return evening
        }
        if let morning = slot(on: date, hour: morningHour, calendar: calendar),
           date >= morning {
            return morning
        }

        let previousDay = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return slot(on: previousDay, hour: eveningHour, calendar: calendar) ?? previousDay
    }

    static func shouldRefresh(
        now: Date,
        lastSuccessfulRefreshAt: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            lastAttemptedSlotAt: nil,
            calendar: calendar
        )
    }

    static func shouldAttempt(
        now: Date,
        lastSuccessfulRefreshAt: Date?,
        lastAttemptedSlotAt: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        let latestSlot = latestScheduledSlot(before: now, calendar: calendar)
        if let lastSuccessfulRefreshAt, lastSuccessfulRefreshAt >= latestSlot {
            return false
        }
        // An attempted slot is diagnostic state, not a retry budget. A failed
        // automatic read must remain eligible for the persistent recovery lane.
        _ = lastAttemptedSlotAt
        return true
    }

    static func nextScheduledSlot(after date: Date, calendar: Calendar = .current) -> Date {
        if let morning = slot(on: date, hour: morningHour, calendar: calendar),
           date < morning {
            return morning
        }
        if let evening = slot(on: date, hour: eveningHour, calendar: calendar),
           date < evening {
            return evening
        }

        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return slot(on: nextDay, hour: morningHour, calendar: calendar) ?? nextDay
    }

    static func delayUntilNextSlot(from date: Date, calendar: Calendar = .current) -> TimeInterval {
        max(0, nextScheduledSlot(after: date, calendar: calendar).timeIntervalSince(date))
    }

    private static func slot(on date: Date, hour: Int, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: date
        )
    }
}
