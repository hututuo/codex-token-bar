import XCTest
@testable import CodexTokenBar

final class CodexRadarDetailRefreshScheduleTests: XCTestCase {
    func testLatestSlotBeforeMorningIsPreviousDayEvening() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 07:30")

        let slot = CodexRadarDetailRefreshSchedule.latestScheduledSlot(before: now, calendar: calendar)

        XCTAssertEqual(Self.string(slot), "2026-07-06 18:00")
    }

    func testLatestSlotAfterMorningIsTodayMorning() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 08:01")

        let slot = CodexRadarDetailRefreshSchedule.latestScheduledSlot(before: now, calendar: calendar)

        XCTAssertEqual(Self.string(slot), "2026-07-07 08:00")
    }

    func testLatestSlotAfterEveningIsTodayEvening() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 18:30")

        let slot = CodexRadarDetailRefreshSchedule.latestScheduledSlot(before: now, calendar: calendar)

        XCTAssertEqual(Self.string(slot), "2026-07-07 18:00")
    }

    func testStartupCatchUpRunsWhenLastSuccessIsOlderThanLatestSlot() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 09:00")
        let lastSuccess = try Self.date("2026-07-06 18:00")

        XCTAssertTrue(CodexRadarDetailRefreshSchedule.shouldRefresh(now: now, lastSuccessfulRefreshAt: lastSuccess, calendar: calendar))
    }

    func testStartupCatchUpDoesNotRepeatAfterLatestSlotSucceeded() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 09:00")
        let lastSuccess = try Self.date("2026-07-07 08:00")

        XCTAssertFalse(CodexRadarDetailRefreshSchedule.shouldRefresh(now: now, lastSuccessfulRefreshAt: lastSuccess, calendar: calendar))
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func date(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }

    private static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
