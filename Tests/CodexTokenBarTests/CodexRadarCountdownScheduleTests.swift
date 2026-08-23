import XCTest
@testable import CodexTokenBar

final class CodexRadarCountdownScheduleTests: XCTestCase {
    func testLongWindowUsesMinuteTicksThenSecondTicksForFinalMinute() {
        let start = Date(timeIntervalSince1970: 0)
        let schedule = CodexRadarCountdownTimelineSchedule(
            deadline: Date(timeIntervalSince1970: 125)
        )

        let entries = Array(schedule.entries(from: start, mode: .normal))

        XCTAssertEqual(entries.map(\.timeIntervalSince1970), [0, 60, 120, 121, 122, 123, 124, 125])
    }

    func testExpiredOrMissingDeadlineEmitsOnlyInitialEntry() {
        let start = Date(timeIntervalSince1970: 100)

        let expired = CodexRadarCountdownTimelineSchedule(
            deadline: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(
            Array(expired.entries(from: start, mode: .normal)).map(\.timeIntervalSince1970),
            [100]
        )

        let missing = CodexRadarCountdownTimelineSchedule(deadline: nil)
        XCTAssertEqual(
            Array(missing.entries(from: start, mode: .normal)).map(\.timeIntervalSince1970),
            [100]
        )
    }
}
