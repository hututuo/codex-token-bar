import SwiftUI
import XCTest
@testable import CodexTokenBar

final class DashboardHeaderRedesignTests: XCTestCase {
    func testClientIdentityUsesExplicitCLIAndDesktopLabelsWithoutChangingIDs() {
        XCTAssertEqual(UsageClient.claudeCode.rawValue,"claudeCode")
        XCTAssertEqual(UsageClient.claudeCode.displayName,"Claude CLI")
        XCTAssertEqual(UsageClient.claudeDesktop.displayName,"Claude Desktop")
        XCTAssertEqual(ClientDisplayScope.title("claudeCode"),"Claude CLI")
    }
    func testBothCurrentModelRowsPrecedeAnyLegacyRowsWithoutLosingRecords() {
        let ids=["codex|gpt-5.6-sol","codex|gpt-6-astra","claudeCode|claude-opus-4-6","claudeDesktop|claude-opus-5-5","claudeCode|claude-sonnet-5-5"]
        let rows=ids.map { FloatingTodayModelUsageItem(id:$0,label:$0,tokens:100,share:0.2,costUSD:1,usesIndependentQuota:false,referenceCostUSD:nil,color:.blue) }
        let context=ClientModelCostPeriods(lifetime:rows,today:[],sevenDay:[])
        let groups=context.groups(.lifetime)
        XCTAssertEqual(groups.map(\.id),["client:codex","client:claudeDesktop","client:claudeCode","other:claudeCode"])
        XCTAssertEqual(groups[0].items.map(\.id),[ids[1],ids[0]])
        XCTAssertTrue(groups.filter { !$0.isSecondary }.allSatisfy { $0.items.count <= 4 })
        XCTAssertEqual(groups.last?.items.map(\.id),[ids[2]])
        XCTAssertFalse(groups[0].items.contains{$0.id==ids[2]},"A legacy CLI model cannot outrank a newer Desktop version of the same family")
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(),ids.sorted())
        XCTAssertEqual(groups.flatMap(\.items).reduce(0) { $0 + $1.tokens }, 500)
        XCTAssertEqual(groups.flatMap(\.items).compactMap(\.costUSD).reduce(0,+), 5)
    }
    func testUnlabelledCompactPlaceholdersHaveNoRepresentationOrHeight() {
        let omitted:[QuotaSidebarItem]=[.modeltrace,.tps,.radar,.credits,.clientUsage]
        XCTAssertTrue(omitted.allSatisfy{!$0.hasCompactRepresentation && !$0.usesCompactDot})
        XCTAssertTrue(QuotaSidebarContentOrder.compactIDs(items:omitted,quotas:[]).isEmpty)
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items:omitted + [.speed,.models,.tasks],quotas:[]),["speed","models","tasks"])
    }
}
