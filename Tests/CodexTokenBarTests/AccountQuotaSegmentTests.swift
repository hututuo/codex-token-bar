import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaSegmentTests: XCTestCase {
    func testTwoSegmentStripBudgetGivesEachProgressBarAtLeast160Points() {
        let accountTitleWidth = ("PRO" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
        ).width
        let accountSubtitleWidth = ("本地账户额度" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .medium)]
        ).width

        XCTAssertLessThanOrEqual(ceil(max(accountTitleWidth, accountSubtitleWidth)), AccountQuotaStripLayout.accountLabelWidth)
        XCTAssertEqual(AccountQuotaStripLayout.combinedQuotaSegmentsWidth, 346)
        XCTAssertEqual(AccountQuotaSegmentLayout.twoSegmentWidth, 170)
        XCTAssertEqual(AccountQuotaSegmentLayout.progressBarWidth, AccountQuotaSegmentLayout.twoSegmentWidth)
        XCTAssertGreaterThanOrEqual(AccountQuotaSegmentLayout.progressBarWidth, 160)
    }

    func testWorstCaseSegmentCopyFitsNativeFontBudgetWithoutEllipsis() {
        let window = AccountQuotaWindow(
            label: "7d",
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 1_799_712_000)
        )
        let presentation = AccountQuotaSegmentPresentation(window: window)
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let progressFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let topWidth = (presentation.title as NSString).size(withAttributes: [.font: titleFont]).width
            + AccountQuotaSegmentLayout.topRowSpacing
            + (presentation.resetText as NSString).size(withAttributes: [.font: resetFont]).width
        let progressWidth = AccountQuotaSegmentLayout.progressHorizontalPadding * 2
            + (presentation.remainingText as NSString).size(withAttributes: [.font: progressFont]).width
            + AccountQuotaSegmentLayout.progressTextSpacing
            + (presentation.usedText as NSString).size(withAttributes: [.font: progressFont]).width

        XCTAssertEqual(presentation.title, "7天")
        XCTAssertTrue(presentation.resetText.hasPrefix("重置 "))
        XCTAssertEqual(presentation.remainingText, "剩 100%")
        XCTAssertEqual(presentation.usedText, "已用 0%")
        XCTAssertFalse(presentation.allVisibleText.contains { $0.contains("…") || $0.contains("...") })
        XCTAssertLessThanOrEqual(ceil(topWidth), AccountQuotaSegmentLayout.twoSegmentWidth)
        XCTAssertLessThanOrEqual(ceil(progressWidth), AccountQuotaSegmentLayout.progressBarWidth)
    }

    @MainActor
    func testHostedProductionSegmentKeepsFullWidthProgressBudget() {
        let window = AccountQuotaWindow(
            label: "7d",
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 1_799_712_000)
        )
        let hostingView = NSHostingView(
            rootView: AccountQuotaSegment(window: window, accent: .blue)
                .frame(width: AccountQuotaSegmentLayout.twoSegmentWidth)
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.fittingSize.width, AccountQuotaSegmentLayout.twoSegmentWidth, accuracy: 0.5)
        XCTAssertEqual(hostingView.fittingSize.height, AccountQuotaSegmentLayout.controlHeight, accuracy: 0.5)
    }
}
