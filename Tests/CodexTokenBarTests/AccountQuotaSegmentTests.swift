import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaSegmentTests: XCTestCase {
    func testAccountLabelPresentationNeverSelectsBlankTitle() {
        let cases: [(limitName: String?, planType: String?, visual: String, semantic: String)] = [
            (nil, nil, "账户额度", "账户额度"),
            ("", "", "账户额度", "账户额度"),
            (" \n\t ", "   ", "账户额度", "账户额度"),
            ("   ", "pro", "PRO", "PRO"),
            ("\n", " plus ", "PLUS", "PLUS"),
            ("\t", "Team", "TEAM", "TEAM"),
            ("GPT-5.3-Codex-Spark", " \n pro \t", "PRO", "GPT-5.3-Codex-Spark"),
            ("  TEAM  ", nil, "TEAM", "TEAM"),
            (nil, " plus ", "PLUS", "PLUS"),
        ]

        for item in cases {
            let snapshot = AccountQuotaSnapshot(
                planType: item.planType,
                limitName: item.limitName,
                status: "额度未读取"
            )
            let presentation = AccountQuotaAccountLabelPresentation(snapshot: snapshot)

            XCTAssertEqual(presentation.title, item.visual)
            XCTAssertEqual(presentation.accessibilityLabel, item.semantic)
            XCTAssertFalse(presentation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(presentation.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(presentation.visibleTextFitsBudget)
        }
    }

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
        hostingView.frame = NSRect(x: 0, y: 0, width: AccountQuotaStripLayout.accountLabelWidth, height: 35)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let presentation = AccountQuotaAccountLabelPresentation(snapshot: snapshot)
        let accessibilityElement = AccountQuotaAccountAccessibilityRepresentation.makeElement(
            presentation: presentation
        )

        XCTAssertEqual(hostingView.fittingSize.width, AccountQuotaStripLayout.accountLabelWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, AccountQuotaSegmentLayout.controlHeight)
        XCTAssertEqual(accessibilityElement.accessibilityLabel(), snapshot.displayName)
        XCTAssertEqual(accessibilityElement.accessibilityValue() as? String, snapshot.status)
        XCTAssertEqual(accessibilityElement.accessibilityHelp(), presentation.help)
        XCTAssertEqual(presentation.subtitle, "读取失败")
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

    func testUnavailableStripHasOneCompactStatusOwnerWithCompleteAccountSemantics() {
        let snapshot = AccountQuotaSnapshot(
            planType: "pro",
            limitName: "GPT-5.3-Codex-Spark",
            status: "读取账户额度失败：网络连接已中断，请稍后重试"
        )
        let presentation = AccountQuotaStripPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.visibleCompactStatusTexts, ["读取失败"])
        XCTAssertEqual(presentation.accountLabel.accessibilityLabel, snapshot.displayName)
        XCTAssertEqual(presentation.accountLabel.accessibilityValue, snapshot.status)
        XCTAssertTrue(presentation.accountLabel.help.contains(snapshot.status))
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

    @MainActor
    func testResetCreditDisclosureHeaderMakesTheWholeStripActionable() throws {
        var pressCount = 0
        let width: CGFloat = 520
        let credit = AccountQuotaResetCredit(
            id: "full-width-disclosure",
            status: "available",
            resetType: "codex_rate_limits",
            grantedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date().addingTimeInterval(6 * 60 * 60),
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: "One free rate limit reset",
            descriptionText: "A reset credit used to verify the disclosure hit area.",
            profileUserID: "@test",
            profileImageURL: nil
        )
        let hostingView = NSHostingView(
            rootView: AccountQuotaResetCreditDisclosureHeader(
                index: 1,
                credit: credit,
                isExpanded: false,
                onToggle: { pressCount += 1 }
            )
            .frame(width: width)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 52)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        for x in [CGFloat(4), width / 2, width - 4] {
            try clickAccountQuotaHostedView(
                window: window,
                at: NSPoint(x: x, y: hostingView.bounds.midY)
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(pressCount, 3)
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

@MainActor
private func clickAccountQuotaHostedView(window: NSWindow, at location: NSPoint) throws {
    let timestamp = ProcessInfo.processInfo.systemUptime
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    )
    window.sendEvent(mouseDown)
    window.sendEvent(mouseUp)
}
