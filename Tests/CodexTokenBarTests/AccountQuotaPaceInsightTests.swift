import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaPaceInsightTests: XCTestCase {
    func testEveryReachableDetailBoundaryFitsWithoutEllipsis() {
        let cases: [(remaining: Int, expected: Int, hours: Int?, expectedText: String)] = [
            (100, 100, nil, "7d余100% · 均100% · 贴线"),
            (0, 100, nil, "7d余0% · 均100% · 低100%"),
            (100, 0, nil, "7d余100% · 均0% · 高100%"),
            (100, 21, 36, "7d余100% · 均21% · 高79% · 36h"),
            (0, 21, 36, "7d余0% · 均21% · 低21% · 36h"),
        ]
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)

        for item in cases {
            let detail = AccountQuotaPaceDetailText.make(
                remainingPercent: item.remaining,
                expectedRemainingPercent: item.expected,
                roundedRemainingHours: item.hours
            )
            let width = (detail as NSString).size(withAttributes: [.font: detailFont]).width

            XCTAssertEqual(detail, item.expectedText)
            XCTAssertFalse(detail.contains("…"))
            XCTAssertLessThanOrEqual(ceil(width), AccountQuotaPaceInsightLayout.textWidth)
        }
    }

    func testPaceLayoutFitsReachableLongestInsightAndCadenceWithoutSqueezingQuotaSegments() throws {
        let snapshot = makeLongestReachableSnapshot()
        let insight = try XCTUnwrap(snapshot.sevenDayPaceStatus)
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let titleWidth = (insight.title as NSString).size(withAttributes: [.font: titleFont]).width
        let detailWidth = (insight.detail as NSString)
            .size(withAttributes: [.font: detailFont]).width

        XCTAssertEqual(insight.detail, "7d余100% · 均21% · 高79% · 36h")
        XCTAssertLessThanOrEqual(ceil(titleWidth), AccountQuotaPaceInsightLayout.textWidth)
        XCTAssertLessThanOrEqual(ceil(detailWidth), AccountQuotaPaceInsightLayout.textWidth)
        XCTAssertEqual(
            AccountQuotaPaceInsightLayout.cadenceWidth,
            AccountQuotaRefreshCadenceMenuLayout.controlWidth
        )
        XCTAssertGreaterThanOrEqual(AccountQuotaStripLayout.combinedQuotaSegmentsWidth, 320)
    }

    @MainActor
    func testHostedReachableLongestPaceUsesBudgetedWidthWithTenMinuteCadence() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AccountQuotaRefreshCadence.storageKey)
        defaults.set(AccountQuotaRefreshCadence.tenMinutes.rawValue, forKey: AccountQuotaRefreshCadence.storageKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AccountQuotaRefreshCadence.storageKey)
            } else {
                defaults.removeObject(forKey: AccountQuotaRefreshCadence.storageKey)
            }
        }

        let hostingView = NSHostingView(
            rootView: AccountQuotaPaceInsight(snapshot: makeLongestReachableSnapshot())
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hostingView.fittingSize.width,
            AccountQuotaPaceInsightLayout.controlWidth,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 42)
        XCTAssertEqual(
            AccountQuotaRefreshCadenceMenuPresentation(selectionRaw: AccountQuotaRefreshCadence.tenMinutes.rawValue).visibleLabel,
            "额度刷新 10 分钟"
        )
    }

    private func makeLongestReachableSnapshot() -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            sevenDay: AccountQuotaWindow(
                label: "7d",
                usedPercent: 0,
                resetsAt: Date().addingTimeInterval(36 * 60 * 60)
            ),
            status: "额度已读取"
        )
    }
}
