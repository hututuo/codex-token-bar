import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaSegmentTests: XCTestCase {
    func testAccountLabelPresentationFallsBackWithin84PointsAndPreservesFullSemantics() {
        let available = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: nil),
            planType: "pro",
            limitName: "GPT-5.3-Codex-Spark",
            status: "额度已读取"
        )
        let unavailable = AccountQuotaSnapshot(
            planType: "enterprise-plan-name-that-does-not-fit",
            limitName: "GPT-5.3-Codex-Spark",
            status: "读取账户额度失败：网络连接已中断，请稍后重试"
        )
        let availablePresentation = AccountQuotaAccountLabelPresentation(snapshot: available)
        let unavailablePresentation = AccountQuotaAccountLabelPresentation(snapshot: unavailable)

        XCTAssertEqual(availablePresentation.title, "PRO")
        XCTAssertEqual(availablePresentation.subtitle, "本地账户额度")
        XCTAssertEqual(unavailablePresentation.title, "账户额度")
        XCTAssertEqual(unavailablePresentation.subtitle, "读取失败")
        XCTAssertEqual(unavailablePresentation.accessibilityLabel, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(unavailablePresentation.accessibilityValue, unavailable.status)
        XCTAssertTrue(unavailablePresentation.help.contains("GPT-5.3-Codex-Spark"))
        XCTAssertTrue(unavailablePresentation.help.contains(unavailable.status))
        XCTAssertTrue([availablePresentation, unavailablePresentation].allSatisfy(\.visibleTextFitsBudget))
    }

    @MainActor
    func testHostedLongAccountNameAndFailureStatusStayInsideAccountColumn() {
        let snapshot = AccountQuotaSnapshot(
            planType: "enterprise-plan-name-that-does-not-fit",
            limitName: "GPT-5.3-Codex-Spark",
            status: "读取账户额度失败：网络连接已中断，请稍后重试"
        )
        let hostingView = NSHostingView(rootView: AccountQuotaAccountLabel(snapshot: snapshot))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.fittingSize.width, AccountQuotaStripLayout.accountLabelWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, AccountQuotaSegmentLayout.controlHeight)
    }

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

    func testNoResetLayoutKeepsPaceAtTrailingEdgeWithoutSplittingQuotaBars() {
        XCTAssertEqual(AccountQuotaStripLayout.noResetSpacerMinimumWidth, AccountQuotaStripLayout.resetCreditWidth)
        XCTAssertEqual(AccountQuotaStripLayout.trailingEdge(hasResetCredit: true), AccountQuotaStripLayout.controlWidth - AccountQuotaStripLayout.horizontalPadding)
        XCTAssertEqual(AccountQuotaStripLayout.trailingEdge(hasResetCredit: false), AccountQuotaStripLayout.controlWidth - AccountQuotaStripLayout.horizontalPadding)
        XCTAssertEqual(AccountQuotaSegmentLayout.twoSegmentWidth, 170)
        XCTAssertEqual(AccountQuotaSegmentLayout.singleSegmentWidth, AccountQuotaStripLayout.combinedQuotaSegmentsWidth)
    }

    @MainActor
    func testHostedUnavailableAndSingleQuotaStripsKeepFull980PointFrame() {
        let unavailable = AccountQuotaSnapshot(status: "额度暂时不可用：网络连接已中断，请稍后重试")
        let singleQuota = AccountQuotaSnapshot(
            fiveHour: AccountQuotaWindow(label: "5h", usedPercent: 20, resetsAt: nil),
            planType: "pro",
            status: "额度已读取"
        )

        for snapshot in [unavailable, singleQuota] {
            let hostingView = NSHostingView(
                rootView: AccountQuotaStrip(snapshot: snapshot, showingResetCreditDetails: .constant(false))
            )
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertEqual(hostingView.fittingSize.width, AccountQuotaStripLayout.controlWidth, accuracy: 0.5)
        }
        XCTAssertEqual(AccountQuotaSegmentLayout.singleSegmentWidth, 346)
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
