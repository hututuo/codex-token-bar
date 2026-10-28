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
        XCTAssertEqual(Array(groups.prefix(2)).map(\.id),["6","claude:latest"])
        XCTAssertEqual(Set(groups[1].items.map(\.id)),Set([ids[3],ids[4]]))
        XCTAssertFalse(groups[1].items.contains{$0.id==ids[2]},"A legacy CLI model cannot outrank a newer Desktop version of the same family")
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(),ids.map { $0.hasPrefix("codex|") ? String($0.dropFirst(6)) : $0 }.sorted())
    }
    func testUnlabelledCompactPlaceholdersHaveNoRepresentationOrHeight() {
        let omitted:[QuotaSidebarItem]=[.modeltrace,.tps,.radar,.credits,.clientUsage]
        XCTAssertTrue(omitted.allSatisfy{!$0.hasCompactRepresentation && !$0.usesCompactDot})
        XCTAssertTrue(QuotaSidebarContentOrder.compactIDs(items:omitted,quotas:[]).isEmpty)
        XCTAssertEqual(QuotaSidebarContentOrder.compactIDs(items:omitted + [.speed,.models,.tasks],quotas:[]),["speed","models","tasks"])
    }
}
