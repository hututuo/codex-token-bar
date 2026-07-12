import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaPaceInsightTests: XCTestCase {
    func testPaceLayoutFitsCommonInsightAndCadenceWithoutSqueezingQuotaSegments() {
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let titleWidth = ("余量低不少，先省着" as NSString).size(withAttributes: [.font: titleFont]).width
        let detailWidth = ("7d 剩 20% · 均速应剩 45% · 余量低 25%" as NSString)
            .size(withAttributes: [.font: detailFont]).width

        XCTAssertLessThanOrEqual(ceil(titleWidth), AccountQuotaPaceInsightLayout.textWidth)
        XCTAssertLessThanOrEqual(ceil(detailWidth), AccountQuotaPaceInsightLayout.textWidth)
        XCTAssertEqual(
            AccountQuotaPaceInsightLayout.cadenceWidth,
            AccountQuotaRefreshCadenceMenuLayout.controlWidth
        )
        XCTAssertGreaterThanOrEqual(AccountQuotaStripLayout.combinedQuotaSegmentsWidth, 320)
    }

    @MainActor
    func testHostedPaceInsightUsesBudgetedWidthWithFullCadenceControl() {
        let hostingView = NSHostingView(
            rootView: AccountQuotaPaceInsight(snapshot: .empty)
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hostingView.fittingSize.width,
            AccountQuotaPaceInsightLayout.controlWidth,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(hostingView.fittingSize.height, 42)
    }
}
