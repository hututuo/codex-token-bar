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
        let latestSlot = latestScheduledSlot(before: now, calendar: calendar)
        guard let lastSuccessfulRefreshAt else { return true }
        return lastSuccessfulRefreshAt < latestSlot
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
