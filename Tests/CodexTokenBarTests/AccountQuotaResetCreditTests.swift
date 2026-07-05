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
        let laterCredit = makeCredit(id: "later", expiresAt: now.addingTimeInterval(2.2 * 24 * 60 * 60))
        let finalDayCredit = makeCredit(id: "final-day", expiresAt: now.addingTimeInterval(5.2 * 60 * 60))
        let finalHourCredit = makeCredit(id: "final-hour", expiresAt: now.addingTimeInterval(34.2 * 60))

        XCTAssertEqual(laterCredit.compactExpiryCountdownText(relativeTo: now), "3天")
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
                makeCredit(id: "later", expiresAt: now.addingTimeInterval(2.2 * 24 * 60 * 60))
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
        XCTAssertEqual(laterSnapshot.compactResetCreditRateBarSuffix, " · 1卡 · 3天")
        XCTAssertEqual(finalHourSnapshot.compactResetCreditRateBarSuffix, " · 1卡 · 35m")
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
