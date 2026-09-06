import Foundation
import XCTest
@testable import CodexTokenBar

final class QuotaHistoryProtectionTests: XCTestCase {
    func testWindowPoliciesCanBeTunedIndependentlyWithoutChangingTheFiveHourDefaults() {
        let strictWeekly = QuotaHistoryProtectionPolicy(
            newCycleResetDelta: 1800, maximumNewCycleUsedPercent: 30,
            resetJitterTolerance: 5, correctionSampleCount: 4, correctionEvidenceDuration: 600
        )
        var five = QuotaHistoryProtection(policy: .fiveHour)
        var seven = QuotaHistoryProtection(policy: strictWeekly)
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        let reset = at.addingTimeInterval(20_000)
        _ = five.observe(usedPercent: 90, resetsAt: reset, observedAt: at)
        _ = seven.observe(usedPercent: 90, resetsAt: reset, observedAt: at)
        let next = reset.addingTimeInterval(1801)
        XCTAssertEqual(five.observe(usedPercent: 80, resetsAt: next, observedAt: at.addingTimeInterval(1)).generation, 1)
        let rejected = seven.observe(usedPercent: 80, resetsAt: next, observedAt: at.addingTimeInterval(1))
        XCTAssertNil(rejected.usedPercent)
        XCTAssertEqual(rejected.generation, 0)
        XCTAssertEqual(seven.observe(usedPercent: 30, resetsAt: next, observedAt: at.addingTimeInterval(2)).generation, 1)
        XCTAssertEqual(QuotaHistoryProtectionPolicy.fiveHour.maximumNewCycleUsedPercent, 100)
        XCTAssertEqual(QuotaHistoryProtectionPolicy.sevenDay.maximumNewCycleUsedPercent, 100)
    }

    func testInitialAndForwardBoundaryAcceptEveryValidPercentageForEachWindow() {
        forEachWindow { window in
            for used in [0, 2, 50, 80, 100] {
                var protection = QuotaHistoryProtection()
                let reset = date(20_000)

                let initial = protection.observe(
                    usedPercent: 90,
                    resetsAt: reset,
                    observedAt: date(0)
                )
                XCTAssertEqual(initial.usedPercent, 90, window)
                XCTAssertEqual(initial.resetsAt, reset, window)
                XCTAssertEqual(initial.generation, 0, window)
                XCTAssertTrue(initial.isAnchor, window)

                let exactBoundary = protection.observe(
                    usedPercent: used,
                    resetsAt: reset.addingTimeInterval(1_800),
                    observedAt: date(1)
                )
                XCTAssertEqual(exactBoundary.generation, 0, window)

                let newCycle = protection.observe(
                    usedPercent: used,
                    resetsAt: reset.addingTimeInterval(1_801),
                    observedAt: date(2)
                )
                XCTAssertEqual(newCycle.usedPercent, used, window)
                XCTAssertEqual(newCycle.resetsAt, reset.addingTimeInterval(1_801), window)
                XCTAssertEqual(newCycle.generation, 1, window)
                XCTAssertTrue(newCycle.isAnchor, window)
                XCTAssertFalse(newCycle.needsEvidence, window)
            }
        }
    }

    func testResetBoundaryUsesStrictGreaterThanWithTimestampTolerance() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let reset = date(20_000)
            protection.observe(usedPercent: 40, resetsAt: reset, observedAt: date(0))

            let residue = protection.observe(
                usedPercent: 60,
                resetsAt: reset.addingTimeInterval(1_800 + 0.000_000_5),
                observedAt: date(1)
            )
            XCTAssertEqual(residue.generation, 0, window)
            XCTAssertEqual(residue.usedPercent, 60, window)
            XCTAssertEqual(residue.resetsAt, reset, window)

            let beyondTolerance = protection.observe(
                usedPercent: 1,
                resetsAt: reset.addingTimeInterval(1_800 + 0.000_002),
                observedAt: date(2)
            )
            XCTAssertEqual(beyondTolerance.generation, 1, window)
            XCTAssertEqual(beyondTolerance.usedPercent, 1, window)
            XCTAssertTrue(beyondTolerance.isAnchor, window)
        }
    }

    func testBackwardAndCreepingResetValuesKeepTheOriginalAnchor() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let anchor = date(20_000)
            protection.observe(usedPercent: 12, resetsAt: anchor, observedAt: date(0))

            let backward = protection.observe(
                usedPercent: 0,
                resetsAt: anchor.addingTimeInterval(-2_000),
                observedAt: date(1)
            )
            XCTAssertNil(backward.usedPercent, window)
            XCTAssertTrue(backward.needsEvidence, window)
            XCTAssertEqual(backward.resetsAt, anchor, window)
            XCTAssertEqual(backward.generation, 0, window)

            for (index, drift) in [600.0, 1_200.0, 1_800.0].enumerated() {
                let result = protection.observe(
                    usedPercent: 13,
                    resetsAt: anchor.addingTimeInterval(drift),
                    observedAt: date(100 + Double(index * 300))
                )
                XCTAssertEqual(result.usedPercent, 13, window)
                XCTAssertEqual(result.resetsAt, anchor, window)
                XCTAssertEqual(result.generation, 0, window)
            }

            let newCycle = protection.observe(
                usedPercent: 70,
                resetsAt: anchor.addingTimeInterval(1_801),
                observedAt: date(1_000)
            )
            XCTAssertEqual(newCycle.usedPercent, 70, window)
            XCTAssertEqual(newCycle.generation, 1, window)
            XCTAssertTrue(newCycle.isAnchor, window)
        }
    }

    func testLowerValuesNeedThreeNewSamplesAcrossFiveMinutesAndThenRecoverNormally() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let anchor = date(20_000)
            protection.observe(usedPercent: 12, resetsAt: anchor, observedAt: date(0))

            let first = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(10))
            XCTAssertNil(first.usedPercent, window)
            XCTAssertTrue(first.needsEvidence, window)

            let second = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(310))
            XCTAssertNil(second.usedPercent, window)
            XCTAssertTrue(second.needsEvidence, window)

            let correction = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(311))
            XCTAssertEqual(correction.usedPercent, 8, window)
            XCTAssertEqual(correction.resetsAt, anchor, window)
            XCTAssertEqual(correction.generation, 0, window)
            XCTAssertTrue(correction.isCorrection, window)
            XCTAssertTrue(correction.needsEvidence, window)

            let recoveredUpper = protection.observe(usedPercent: 9, resetsAt: anchor, observedAt: date(312))
            XCTAssertEqual(recoveredUpper.usedPercent, 9, window)
            XCTAssertFalse(recoveredUpper.isCorrection, window)
            XCTAssertFalse(recoveredUpper.needsEvidence, window)
        }
    }

    func testDuplicateAndOutOfOrderObservationsDoNotAdvanceCorrectionCandidate() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let anchor = date(20_000)
            protection.observe(usedPercent: 12, resetsAt: anchor, observedAt: date(0))
            protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(10))

            let duplicate = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(10))
            XCTAssertNil(duplicate.usedPercent, window)
            XCTAssertFalse(duplicate.needsEvidence, window)
            XCTAssertEqual(duplicate.generation, 0, window)

            let outOfOrder = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(9))
            XCTAssertNil(outOfOrder.usedPercent, window)
            XCTAssertFalse(outOfOrder.needsEvidence, window)

            // Only the samples at 10 and 310 have counted so far. If either
            // replay above advanced the candidate, this would confirm early.
            let secondFresh = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(310))
            XCTAssertNil(secondFresh.usedPercent, window)
            XCTAssertTrue(secondFresh.needsEvidence, window)

            let confirmed = protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(311))
            XCTAssertEqual(confirmed.usedPercent, 8, window)
            XCTAssertTrue(confirmed.isCorrection, window)
        }
    }

    func testInvalidValuesResetCandidatesAndMissingResetCannotConfirmDecline() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let anchor = date(2_000)
            protection.observe(usedPercent: 12, resetsAt: anchor, observedAt: date(0))
            protection.observe(usedPercent: 8, resetsAt: anchor, observedAt: date(10))

            let missing = protection.observe(usedPercent: nil, resetsAt: anchor, observedAt: date(20))
            XCTAssertNil(missing.usedPercent, window)
            XCTAssertTrue(missing.needsEvidence, window)

            let invalid = protection.observe(usedPercent: 101, resetsAt: anchor, observedAt: date(30))
            XCTAssertNil(invalid.usedPercent, window)
            XCTAssertTrue(invalid.needsEvidence, window)

            for at in [40.0, 340.0, 640.0] {
                let result = protection.observe(usedPercent: 8, resetsAt: nil, observedAt: date(at))
                XCTAssertNil(result.usedPercent, window)
                XCTAssertTrue(result.needsEvidence, window)
            }
        }
    }

    func testIncreasingValuesMaySurviveMissingResetBeforeExpiryButBoundaryAwaitsEvidence() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let anchor = date(2_000)
            protection.observe(usedPercent: 12, resetsAt: anchor, observedAt: date(0))

            let increasingWithoutReset = protection.observe(
                usedPercent: 13,
                resetsAt: nil,
                observedAt: date(20)
            )
            XCTAssertEqual(increasingWithoutReset.usedPercent, 13, window)
            XCTAssertEqual(increasingWithoutReset.resetsAt, anchor, window)

            let expiredWithoutNewBoundary = protection.observe(
                usedPercent: 14,
                resetsAt: nil,
                observedAt: anchor
            )
            XCTAssertNil(expiredWithoutNewBoundary.usedPercent, window)
            XCTAssertTrue(expiredWithoutNewBoundary.needsEvidence, window)
            XCTAssertEqual(expiredWithoutNewBoundary.resetsAt, anchor, window)

            let newBoundary = protection.observe(
                usedPercent: 100,
                resetsAt: date(4_000),
                observedAt: date(2_100)
            )
            XCTAssertEqual(newBoundary.usedPercent, 100, window)
            XCTAssertEqual(newBoundary.generation, 1, window)
            XCTAssertTrue(newBoundary.isAnchor, window)
        }
    }

    func testExpiredFirstAnchorIsRetainedButEmittedAsEvidenceGap() {
        forEachWindow { window in
            var protection = QuotaHistoryProtection()
            let expiredReset = date(100)

            let first = protection.observe(
                usedPercent: 80,
                resetsAt: expiredReset,
                observedAt: date(100)
            )
            XCTAssertNil(first.usedPercent, window)
            XCTAssertEqual(first.resetsAt, expiredReset, window)
            XCTAssertEqual(first.generation, 0, window)
            XCTAssertTrue(first.isAnchor, window)
            XCTAssertTrue(first.needsEvidence, window)

            // A finite reset introduced after an initial no-reset baseline is
            // an anchor, but it cannot retroactively make the expired value a
            // trusted point.
            var lateAnchor = QuotaHistoryProtection()
            lateAnchor.observe(usedPercent: 80, resetsAt: nil, observedAt: date(0))
            let introducedExpired = lateAnchor.observe(
                usedPercent: 90,
                resetsAt: expiredReset,
                observedAt: date(100)
            )
            XCTAssertNil(introducedExpired.usedPercent, window)
            XCTAssertEqual(introducedExpired.resetsAt, expiredReset, window)
            XCTAssertTrue(introducedExpired.isAnchor, window)
            XCTAssertTrue(introducedExpired.needsEvidence, window)
        }
    }

    private func forEachWindow(_ body: (String) -> Void) {
        for window in ["5h", "7d"] {
            body(window)
        }
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
