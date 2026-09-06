import XCTest
@testable import CodexTokenBar

final class QuotaHistoryCyclePolicyTests: XCTestCase {
    func testNewCycleAcceptsAnyValidUsedAfterStrictThirtyMinuteResetAdvance() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        for used in [0, 1, 80, 100] {
            XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
                currentUsedPercent: used,
                currentResetsAt: anchor.addingTimeInterval(1_800),
                acceptedResetsAt: anchor
            ))
            XCTAssertTrue(QuotaHistoryCyclePolicy.startsNewCycle(
                currentUsedPercent: used,
                currentResetsAt: anchor.addingTimeInterval(1_801),
                acceptedResetsAt: anchor
            ))
        }

        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: nil,
            currentResetsAt: anchor.addingTimeInterval(1_801),
            acceptedResetsAt: anchor
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: -1,
            currentResetsAt: anchor.addingTimeInterval(1_801),
            acceptedResetsAt: anchor
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 101,
            currentResetsAt: anchor.addingTimeInterval(1_801),
            acceptedResetsAt: anchor
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 1,
            currentResetsAt: anchor.addingTimeInterval(-1_801),
            acceptedResetsAt: anchor
        ))
    }

    func testTimestampRoundTripResidueDoesNotCrossExactPolicyBoundaries() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(1_800 + 0.000_000_5),
            acceptedResetsAt: anchor
        ))
        XCTAssertTrue(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 0,
            currentResetsAt: anchor.addingTimeInterval(1_800 + 0.000_002),
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
    }

    func testResetJitterBandIsSymmetricAndDoesNotCreateACycle() {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(5 + 0.000_000_5)
        ))
        XCTAssertTrue(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(-5 - 0.000_000_5)
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(5 + 0.000_002)
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.isResetJitter(
            anchor,
            anchor.addingTimeInterval(-5 - 0.000_002)
        ))
        XCTAssertFalse(QuotaHistoryCyclePolicy.startsNewCycle(
            currentUsedPercent: 100,
            currentResetsAt: anchor.addingTimeInterval(5),
            acceptedResetsAt: anchor
        ))
    }
}
