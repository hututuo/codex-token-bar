import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class AccountQuotaRefreshCadenceControlTests: XCTestCase {
    func testPresentationTableShowsEveryCadenceWithoutEllipsis() {
        let presentations = AccountQuotaRefreshCadence.allCases.map {
            AccountQuotaRefreshCadenceMenuPresentation(selectionRaw: $0.rawValue)
        }

        XCTAssertEqual(
            presentations.map(\.visibleLabel),
            [
                "额度刷新 30 秒",
                "额度刷新 1 分钟",
            ]
        )
        XCTAssertTrue(presentations.allSatisfy { !$0.visibleLabel.contains("…") })
        XCTAssertTrue(presentations.allSatisfy { !$0.visibleLabel.contains("...") })
        XCTAssertEqual(presentations.map(\.accessibilityLabel), Array(repeating: "额度刷新", count: 2))
        XCTAssertEqual(
            presentations.map(\.accessibilityValue),
            ["30 秒", "1 分钟"]
        )
        XCTAssertEqual(Set(presentations.map(\.disclosureSystemImage)), ["chevron.down"])
    }

    func testLongestCadenceLabelFitsStableControlWidth() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labelWidth = ("额度刷新 1 分钟" as NSString).size(withAttributes: [.font: font]).width
        let requiredWidth = AccountQuotaRefreshCadenceMenuLayout.horizontalPadding * 2
            + AccountQuotaRefreshCadenceMenuLayout.iconWidth
            + AccountQuotaRefreshCadenceMenuLayout.spacing
            + AccountQuotaRefreshCadenceMenuLayout.disclosureWidth
            + AccountQuotaRefreshCadenceMenuLayout.spacing
            + ceil(labelWidth)

        XCTAssertLessThanOrEqual(requiredWidth, AccountQuotaRefreshCadenceMenuLayout.controlWidth)
    }

    @MainActor
    func testHostedCadenceMenuKeepsStableSizeForCurrentAndLongestValues() {
        for rawValue in [AccountQuotaRefreshCadence.thirtySeconds.rawValue, AccountQuotaRefreshCadence.oneMinute.rawValue] {
            let hostingView = NSHostingView(
                rootView: AccountQuotaRefreshCadenceMenu(selectionRaw: .constant(rawValue))
            )
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                hostingView.fittingSize.width,
                AccountQuotaRefreshCadenceMenuLayout.controlWidth,
                accuracy: 0.5
            )
            XCTAssertEqual(hostingView.fittingSize.height, 28, accuracy: 0.5)
        }
    }
}
