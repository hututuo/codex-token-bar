import Foundation
import XCTest
@testable import CodexTokenBar

final class QuotaMonotonicNormalizerTests: XCTestCase {
    func testOutOfOrderCodexSnapshotCannotMoveUsedPercentBackWithinSameCycle() {
        let reset = Date(timeIntervalSince1970: 1_782_144_492)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 71,
            currentResetsAt: reset,
            previousUsedPercent: 84,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 84)
    }

    func testAcceptsFreshWindowProgressWhileIgnoringStaleSevenDaySnapshot() {
        let reset = Date(timeIntervalSince1970: 1_782_144_492)
        let previous = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 50, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 84, resetsAt: reset),
            planType: "pro",
            limitName: nil,
            accountName: "来先生",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let outOfOrder = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 51, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 71, resetsAt: reset),
            planType: "pro",
            limitName: nil,
            accountName: "来先生",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(outOfOrder, after: previous)

        XCTAssertEqual(adjusted.fiveHour?.usedPercent, 51)
        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 84)
    }

    func testSameResetCycleDoesNotAllowRemainingToIncrease() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 72,
            currentResetsAt: reset,
            previousUsedPercent: 84,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 84)
    }

    func testSameCycleLargeDropIsAcceptedAsRecoveredSpike() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 62,
            currentResetsAt: reset.addingTimeInterval(90),
            previousUsedPercent: 84,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 62)
    }

    func testResetTimestampDriftWithinGraceStillRejectsSmallRegression() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 71,
            currentResetsAt: reset.addingTimeInterval(90),
            previousUsedPercent: 84,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 84)
    }

    func testCrossingResetAllowsQuotaToReturnToFull() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let nextReset = Date(timeIntervalSince1970: 28_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 0,
            currentResetsAt: nextReset,
            previousUsedPercent: 10,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 0)
    }

    func testResetDriftCannotStartLegacyCycleUnlessCurrentQuotaIsFull() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 1,
            currentResetsAt: reset.addingTimeInterval(301),
            previousUsedPercent: 10,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 10)
    }

    func testAuthoritativeCycleIDAllowsImmediatePostResetUsage() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 10,
                resetsAt: reset,
                cycleID: "g3"
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 1,
                resetsAt: reset.addingTimeInterval(301),
                cycleID: "g4"
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 1)
        XCTAssertEqual(adjusted.sevenDay?.cycleID, "g4")
    }

    func testMatchingCycleIDOverridesLargeResetTimestampDrift() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 10,
                resetsAt: reset,
                cycleID: "g3"
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 1,
                resetsAt: reset.addingTimeInterval(900),
                cycleID: "g3"
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 10)
    }

    func testIntroducingCycleIDDoesNotCreateSyntheticReset() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 10, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 1,
                resetsAt: reset.addingTimeInterval(60),
                cycleID: "g3"
            ),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 10)
    }

    func testRecoveredFullUsageSpikeCanReturnToFreshLowerReadingWithinSameReset() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 2,
            currentResetsAt: reset,
            previousUsedPercent: 100,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 2)
    }

    func testDifferentResetWindowIsNotStitchedToPreviousCycle() {
        let previousReset = Date(timeIntervalSince1970: 10_000)
        let currentReset = Date(timeIntervalSince1970: 80_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 22,
            currentResetsAt: currentReset,
            previousUsedPercent: 95,
            previousResetsAt: previousReset
        )

        XCTAssertEqual(adjusted, 22)
    }

    func testSnapshotNormalizationKeepsAccountChangesIndependent() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let previous = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 60, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 90, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "A",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let current = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 10, resetsAt: reset),
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 10, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "B",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.fiveHour?.usedPercent, 10)
        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 10)
    }

    func testStableIdentityPreventsSameDisplayNameAccountsFromBeingStitched() {
        let reset = Date(timeIntervalSince1970: 10_000)
        var previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 18, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: nil,
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        previous.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "home-a",
            stableAccountKey: "account-a",
            planType: "pro",
            limitID: "codex"
        )
        var current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 13, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: nil,
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        current.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "home-a",
            stableAccountKey: "account-b",
            planType: "pro",
            limitID: "codex"
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 13)
    }

    func testStableIdentityKeepsMonotonicProtectionWhenDisplayNameChanges() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let identity = QuotaHistoryIdentity(
            homeIdentity: "home-a",
            stableAccountKey: "account-a",
            planType: "pro",
            limitID: "codex"
        )
        var previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 18, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "旧显示名",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        previous.historyIdentity = identity
        var current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 13, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: "新显示名",
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        current.historyIdentity = identity

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 18)
    }

    func testOneSidedStableIdentityFailsClosedInsteadOfFallingBackToDisplayName() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let previous = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 18, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: nil,
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        var current = AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(label: "7d", usedPercent: 13, resetsAt: reset),
            planType: "pro",
            limitName: "codex",
            accountName: nil,
            status: "额度已更新",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        current.historyIdentity = QuotaHistoryIdentity(
            homeIdentity: "home-a",
            stableAccountKey: "account-b",
            planType: "pro",
            limitID: "codex"
        )

        let adjusted = QuotaMonotonicNormalizer.normalizedSnapshot(current, after: previous)

        XCTAssertEqual(adjusted.sevenDay?.usedPercent, 13)
    }
}
