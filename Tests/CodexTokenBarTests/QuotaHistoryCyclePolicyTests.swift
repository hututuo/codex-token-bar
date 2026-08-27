import XCTest
@testable import CodexTokenBar

final class QuotaHistoryCyclePolicyTests: XCTestCase {
    func testNewCycleRequiresStrictlyMoreThanFiveMinutesAndFullQuota() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(300),
            acceptedResetsAt: anchor
        ))
        XCTAssertTrue(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(301),
            acceptedResetsAt: anchor
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 1,
            currentResetsAt: anchor.addingTimeInterval(301),
            acceptedResetsAt: anchor
        ))
    }

    func testTimestampRoundTripResidueDoesNotCrossExactPolicyBoundaries() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(300 + 0.000_000_5),
            acceptedResetsAt: anchor
        ))
        XCTAssertTrue(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(300 + 0.000_002),
            acceptedResetsAt: anchor
        ))
        XCTAssertTrue(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(5 + 0.000_000_5)
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(5 + 0.000_002)
        ))

        var candidate = QuotaResetStabilityCandidate(
            observedAt: anchor,
            resetsAt: anchor.addingTimeInterval(10_000)
        )
        XCTAssertTrue(candidate.observe(
            observedAt: anchor.addingTimeInterval(300 - 0.000_000_5),
            resetsAt: anchor.addingTimeInterval(10_005 + 0.000_000_5)
        ))
    }

    func testOneToTwoSecondOscillationStabilizesAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        var candidate = QuotaResetStabilityCandidate(observedAt: start, resetsAt: reset)
        for minute in 1..<5 {
            XCTAssertFalse(candidate.observe(
                observedAt: start.addingTimeInterval(Double(minute * 60)),
                resetsAt: reset.addingTimeInterval(Double(minute % 2 + 1))
            ))
        }
        XCTAssertTrue(candidate.observe(
            observedAt: start.addingTimeInterval(5 * 60),
            resetsAt: reset.addingTimeInterval(1)
        ))
    }

    func testWholeBandMayBeExactlyFiveSecondsButCannotAccumulatePastIt() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        var exact = QuotaResetStabilityCandidate(observedAt: start, resetsAt: reset)
        XCTAssertFalse(exact.observe(observedAt: start.addingTimeInterval(60), resetsAt: reset.addingTimeInterval(5)))
        XCTAssertTrue(exact.observe(observedAt: start.addingTimeInterval(300), resetsAt: reset.addingTimeInterval(2)))

        var drifting = QuotaResetStabilityCandidate(observedAt: start, resetsAt: reset)
        for minute in 1...5 {
            XCTAssertFalse(drifting.observe(
                observedAt: start.addingTimeInterval(Double(minute * 60)),
                resetsAt: reset.addingTimeInterval(Double(minute * 4))
            ))
        }
    }
}
