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

    func testShouldAttemptWhenLatestSlotHasNotSucceededOrBeenAttempted() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 09:00")
        let previousSuccess = try Self.date("2026-07-06 18:00")

        XCTAssertTrue(CodexRadarDetailRefreshSchedule.shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: previousSuccess,
            lastAttemptedSlotAt: nil,
            calendar: calendar
        ))
    }

    func testShouldNotAttemptSameSlotAfterAutomaticFailureWasAttempted() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 09:00")
        let previousSuccess = try Self.date("2026-07-06 18:00")
        let attemptedMorning = try Self.date("2026-07-07 08:00")

        XCTAssertFalse(CodexRadarDetailRefreshSchedule.shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: previousSuccess,
            lastAttemptedSlotAt: attemptedMorning,
            calendar: calendar
        ))
    }

    func testShouldAttemptNextSlotAfterPreviousSlotWasAttempted() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 19:00")
        let previousSuccess = try Self.date("2026-07-06 18:00")
        let attemptedMorning = try Self.date("2026-07-07 08:00")

        XCTAssertTrue(CodexRadarDetailRefreshSchedule.shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: previousSuccess,
            lastAttemptedSlotAt: attemptedMorning,
            calendar: calendar
        ))
    }

    func testShouldNotAttemptWhenLatestSlotAlreadySucceeded() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 19:00")
        let eveningSuccess = try Self.date("2026-07-07 18:00")
        let attemptedMorning = try Self.date("2026-07-07 08:00")

        XCTAssertFalse(CodexRadarDetailRefreshSchedule.shouldAttempt(
            now: now,
            lastSuccessfulRefreshAt: eveningSuccess,
            lastAttemptedSlotAt: attemptedMorning,
            calendar: calendar
        ))
    }

    func testNextSlotBeforeMorningIsTodayMorning() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 07:30")

        let nextSlot = CodexRadarDetailRefreshSchedule.nextScheduledSlot(after: now, calendar: calendar)

        XCTAssertEqual(Self.string(nextSlot), "2026-07-07 08:00")
        XCTAssertEqual(CodexRadarDetailRefreshSchedule.delayUntilNextSlot(from: now, calendar: calendar), 30 * 60, accuracy: 0.001)
    }

    func testNextSlotBetweenMorningAndEveningIsTodayEvening() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 09:00")

        let nextSlot = CodexRadarDetailRefreshSchedule.nextScheduledSlot(after: now, calendar: calendar)

        XCTAssertEqual(Self.string(nextSlot), "2026-07-07 18:00")
        XCTAssertEqual(CodexRadarDetailRefreshSchedule.delayUntilNextSlot(from: now, calendar: calendar), 9 * 60 * 60, accuracy: 0.001)
    }

    func testNextSlotAfterEveningIsTomorrowMorning() throws {
        let calendar = Self.calendar
        let now = try Self.date("2026-07-07 19:00")

        let nextSlot = CodexRadarDetailRefreshSchedule.nextScheduledSlot(after: now, calendar: calendar)

        XCTAssertEqual(Self.string(nextSlot), "2026-07-08 08:00")
        XCTAssertEqual(CodexRadarDetailRefreshSchedule.delayUntilNextSlot(from: now, calendar: calendar), 13 * 60 * 60, accuracy: 0.001)
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
