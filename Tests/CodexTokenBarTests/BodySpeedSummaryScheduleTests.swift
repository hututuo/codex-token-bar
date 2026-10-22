import XCTest
@testable import CodexTokenBar

final class BodySpeedSummaryScheduleTests: XCTestCase {
    private func sample(_ ended: Double) -> ObservedSpeedSample {
        .init(id: "id", threadID: "s", turnID: "t", itemID: "i", model: "gpt-6.1-sol",
              startedAt: ended - 2, endedAt: ended, outputTokens: 100, outputCharacters: 400,
              outputBytes: 400, chunkCount: 1, durationSeconds: 2, tokensPerSecond: 50,
              confidence: "high", networkWarning: nil, source: "rollout_body", measurementKind: "completed_body", tokenizer: "o200k_base")
    }
    func testInclusiveCutoffAndFutureSamplesTriggerTheNextChange() {
        let next = BodySpeedSummarySchedule.nextChange(samples: [sample(1000)], now: 1200)
        XCTAssertEqual(next, (1300.0).nextUp)
        XCTAssertFalse(BodySpeedSummarySchedule.isDue(now: 1300, lastUpdatedAt: 1200, nextChangeAt: next, samplesChanged: false))
        XCTAssertTrue(BodySpeedSummarySchedule.isDue(now: next, lastUpdatedAt: 1200, nextChangeAt: next, samplesChanged: false))
        XCTAssertEqual(BodySpeedSummarySchedule.nextChange(samples: [sample(1000)], now: next), (1900.0).nextUp)
        XCTAssertEqual(BodySpeedSummarySchedule.nextChange(samples: [sample(1250)], now: 1200), 1250)
    }
    func testUnchangedHistoryDoesNotNeedAOneSecondRescanButChangesAndClockRollbackDo() {
        let next = BodySpeedSummarySchedule.nextChange(samples: [sample(1000)], now: 1001)
        for second in 1002..<1300 {
            XCTAssertFalse(BodySpeedSummarySchedule.isDue(now: Double(second), lastUpdatedAt: 1001, nextChangeAt: next, samplesChanged: false))
        }
        XCTAssertTrue(BodySpeedSummarySchedule.isDue(now: 1002, lastUpdatedAt: 1001, nextChangeAt: next, samplesChanged: true))
        XCTAssertTrue(BodySpeedSummarySchedule.isDue(now: 999, lastUpdatedAt: 1001, nextChangeAt: next, samplesChanged: false))
        XCTAssertTrue(BodySpeedSummarySchedule.isDue(now: 1002, lastUpdatedAt: 0, nextChangeAt: next, samplesChanged: false))
        XCTAssertEqual(BodySpeedSummarySchedule.nextChange(samples: [], now: 1000), .infinity)
        XCTAssertEqual(BodySpeedSummarySchedule.nextChange(samples: [sample(1000)], now: 1000 + 8 * 86400), .infinity)
    }
}
