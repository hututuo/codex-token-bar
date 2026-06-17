import Foundation
import XCTest
@testable import CodexTokenBar

final class QuotaMonotonicNormalizerTests: XCTestCase {
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

    func testCrossingResetAllowsQuotaToReturnToFull() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let nextReset = Date(timeIntervalSince1970: 28_000)
        let adjusted = QuotaMonotonicNormalizer.normalizedUsedPercent(
            currentUsedPercent: 1,
            currentResetsAt: nextReset,
            previousUsedPercent: 83,
            previousResetsAt: reset
        )

        XCTAssertEqual(adjusted, 1)
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
}
