import Foundation
import XCTest
@testable import CodexTokenBar

final class AccountQuotaResetCreditTests: XCTestCase {
    func testDisplaySortKeepsAvailableNearestExpiryFirst() {
        let now = Date(timeIntervalSince1970: 1_000)
        let usedSoon = makeCredit(id: "used-soon", status: "redeemed", expiresAt: now.addingTimeInterval(600), redeemedAt: now)
        let availableLater = makeCredit(id: "available-later", expiresAt: now.addingTimeInterval(7_200))
        let availableSoon = makeCredit(id: "available-soon", expiresAt: now.addingTimeInterval(3_600))
        let snapshot = AccountQuotaSnapshot(
            resetCreditsAvailableCount: 2,
            resetCredits: [availableLater, usedSoon, availableSoon]
        )

        XCTAssertEqual(snapshot.sortedResetCreditsForDisplay.map(\.id), ["available-soon", "available-later", "used-soon"])
        XCTAssertEqual(snapshot.nearestExpiringResetCredit?.id, "available-soon")
    }

    func testRemainingTextAndProgressUseGrantToExpiryWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let credit = makeCredit(
            id: "halfway",
            grantedAt: now.addingTimeInterval(-7_200),
            expiresAt: now.addingTimeInterval(7_200)
        )

        XCTAssertEqual(credit.compactRemainingTimeText(relativeTo: now), "剩 2h")
        XCTAssertEqual(credit.remainingTimeText(relativeTo: now), "约 2 小时后到期")
        XCTAssertEqual(try XCTUnwrap(credit.remainingProgress(relativeTo: now)), 0.5, accuracy: 0.001)
    }

    func testCompactExpiryCountdownUsesDaysUntilFinalDayThenHours() {
        let now = Date(timeIntervalSince1970: 10_000)
        let laterCredit = makeCredit(id: "later", expiresAt: now.addingTimeInterval(2.29 * 24 * 60 * 60))
        let exactDayCredit = makeCredit(id: "exact-day", expiresAt: now.addingTimeInterval(24 * 60 * 60))
        let finalDayCredit = makeCredit(id: "final-day", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
        let finalHourCredit = makeCredit(id: "final-hour", expiresAt: now.addingTimeInterval(34.2 * 60))

        XCTAssertEqual(laterCredit.compactExpiryCountdownText(relativeTo: now), "2.3天")
        XCTAssertEqual(exactDayCredit.compactExpiryCountdownText(relativeTo: now), "1.0天")
        XCTAssertEqual(
            makeCredit(id: "seven-point-five", expiresAt: now.addingTimeInterval(7.5 * 24 * 60 * 60))
                .compactExpiryCountdownText(relativeTo: now),
            "7.5天"
        )
        XCTAssertEqual(
            makeCredit(id: "seven-point-six", expiresAt: now.addingTimeInterval(7.6 * 24 * 60 * 60))
                .compactExpiryCountdownText(relativeTo: now),
            "7.6天"
        )
        XCTAssertEqual(finalDayCredit.compactExpiryCountdownText(relativeTo: now), "6h")
        XCTAssertEqual(finalHourCredit.compactExpiryCountdownText(relativeTo: now), "35m")
    }

    func testStandaloneResetCreditSuffixOnlyMentionsExpiryWhenACardExists() {
        let now = Date()
        let noCardSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: []
        )
        let cardSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "soon", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
            ]
        )

        XCTAssertEqual(noCardSnapshot.compactResetCreditStandaloneSuffix, "")
        XCTAssertEqual(cardSnapshot.compactResetCreditCountSuffix, " · 1卡")
        XCTAssertEqual(cardSnapshot.compactResetCreditStandaloneSuffix, " · 1卡 · 近6h到期")
    }

    func testRateBarResetCreditSuffixIncludesNearestExpiryWhenCardExists() {
        let now = Date()
        let noCardSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: []
        )
        let finalDaySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "soon", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
            ]
        )
        let laterSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "later", expiresAt: now.addingTimeInterval(2.29 * 24 * 60 * 60))
            ]
        )
        let finalHourSnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "minutes", expiresAt: now.addingTimeInterval(34.2 * 60))
            ]
        )

        XCTAssertEqual(noCardSnapshot.compactResetCreditRateBarSuffix, "")
        XCTAssertEqual(finalDaySnapshot.compactResetCreditRateBarSuffix, " · 1卡 · 6h")
        XCTAssertEqual(laterSnapshot.compactResetCreditRateBarSuffix, " · 1卡 · 2.3天")
        XCTAssertEqual(finalHourSnapshot.compactResetCreditRateBarSuffix, " · 1卡 · 35m")
    }

    func testCompactResetCreditSuffixKeepsCountButSkipsUnknownExpiry() {
        let now = Date()
        let availableWithoutExpiry = makeCredit(id: "unknown-expiry", expiresAt: nil)
        let unknownExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [availableWithoutExpiry]
        )
        let knownExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                availableWithoutExpiry,
                makeCredit(id: "known-expiry", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
            ]
        )
        let usedOnlySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "used", status: "redeemed", expiresAt: nil, redeemedAt: now)
            ]
        )
        let expiredOnlySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "expired", status: "expired", expiresAt: now.addingTimeInterval(-60 * 60))
            ]
        )
        let availablePastExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "past-but-available", expiresAt: now.addingTimeInterval(-60 * 60))
            ]
        )

        XCTAssertEqual(unknownExpirySnapshot.availableResetCreditCount, 1)
        XCTAssertEqual(unknownExpirySnapshot.compactResetCreditCountSuffix, " · 1卡")
        XCTAssertEqual(unknownExpirySnapshot.compactResetCreditRateBarSuffix, " · 1卡")
        XCTAssertEqual(unknownExpirySnapshot.compactResetCreditStandaloneSuffix, " · 1卡")
        XCTAssertEqual(knownExpirySnapshot.compactResetCreditRateBarSuffix, " · 2卡 · 6h")
        XCTAssertEqual(knownExpirySnapshot.compactResetCreditStandaloneSuffix, " · 2卡 · 近6h到期")
        XCTAssertEqual(usedOnlySnapshot.compactResetCreditRateBarSuffix, "")
        XCTAssertEqual(usedOnlySnapshot.compactResetCreditStandaloneSuffix, "")
        XCTAssertEqual(expiredOnlySnapshot.compactResetCreditRateBarSuffix, "")
        XCTAssertEqual(expiredOnlySnapshot.compactResetCreditStandaloneSuffix, "")
        XCTAssertEqual(availablePastExpirySnapshot.compactResetCreditRateBarSuffix, " · 1卡")
        XCTAssertEqual(availablePastExpirySnapshot.compactResetCreditStandaloneSuffix, " · 1卡")
    }

    func testResetCreditNearestSummaryOnlyUsesFutureExpiringCards() {
        let now = Date()
        let unknownExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "unknown-expiry", expiresAt: nil)
            ]
        )
        let pastExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "past-but-available", expiresAt: now.addingTimeInterval(-60 * 60))
            ]
        )
        let reportedCountOnlySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 2,
            resetCredits: []
        )
        let futureExpirySnapshot = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(60 * 60)),
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "future", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
            ]
        )

        XCTAssertEqual(unknownExpirySnapshot.availableResetCreditCount, 1)
        XCTAssertNil(unknownExpirySnapshot.resetCreditNearestLineText)
        XCTAssertEqual(unknownExpirySnapshot.resetCreditDetailSummary, "1 张重置卡")

        XCTAssertEqual(pastExpirySnapshot.availableResetCreditCount, 1)
        XCTAssertNil(pastExpirySnapshot.resetCreditNearestLineText)
        XCTAssertEqual(pastExpirySnapshot.resetCreditDetailSummary, "1 张重置卡")

        XCTAssertEqual(reportedCountOnlySnapshot.availableResetCreditCount, 2)
        XCTAssertNil(reportedCountOnlySnapshot.resetCreditNearestLineText)
        XCTAssertEqual(reportedCountOnlySnapshot.resetCreditDetailSummary, "2 张重置卡")

        XCTAssertTrue(try XCTUnwrap(futureExpirySnapshot.resetCreditNearestLineText).hasPrefix("最近 剩 "))
        XCTAssertEqual(futureExpirySnapshot.resetCreditDetailSummary, "1 张重置卡 · 最近 \(try XCTUnwrap(futureExpirySnapshot.nearestFutureExpiringResetCredit).compactExpiryText)")
    }

    func testResetCreditDetailSubtitleOnlyMentionsNearestSortingWithFutureExpiryEvidence() {
        let now = Date()
        let unknownExpirySnapshot = AccountQuotaSnapshot(
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "unknown-expiry", expiresAt: nil)
            ]
        )
        let pastExpirySnapshot = AccountQuotaSnapshot(
            resetCreditsAvailableCount: 0,
            resetCredits: [
                makeCredit(id: "past-but-available", expiresAt: now.addingTimeInterval(-60 * 60))
            ]
        )
        let reportedCountOnlySnapshot = AccountQuotaSnapshot(
            resetCreditsAvailableCount: 2,
            resetCredits: []
        )
        let futureExpirySnapshot = AccountQuotaSnapshot(
            resetCreditsAvailableCount: 1,
            resetCredits: [
                makeCredit(id: "future", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
            ]
        )

        XCTAssertEqual(unknownExpirySnapshot.resetCreditDetailSubtitle, "共 1 张；可用 1 张 · 按状态排序")
        XCTAssertEqual(pastExpirySnapshot.resetCreditDetailSubtitle, "共 1 张；可用 1 张 · 按状态排序")
        XCTAssertEqual(reportedCountOnlySnapshot.resetCreditDetailSubtitle, "2 张可用；未拿到单卡明细")
        XCTAssertEqual(futureExpirySnapshot.resetCreditDetailSubtitle, "共 1 张；可用 1 张 · 按最近到期排序")
    }

    private func makeCredit(
        id: String,
        status: String = "available",
        grantedAt: Date? = Date(timeIntervalSince1970: 0),
        expiresAt: Date?,
        redeemedAt: Date? = nil
    ) -> AccountQuotaResetCredit {
        AccountQuotaResetCredit(
            id: id,
            status: status,
            resetType: "codex_rate_limits",
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: redeemedAt,
            title: "One free rate limit reset",
            descriptionText: "You've been awarded one free rate limit reset for inviting test@example.com",
            profileUserID: "@test",
            profileImageURL: nil
        )
    }
}
