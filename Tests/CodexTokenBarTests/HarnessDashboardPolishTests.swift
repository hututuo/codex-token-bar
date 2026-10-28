import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class HarnessDashboardPolishTests: XCTestCase {
    private func item(_ id: String) -> FloatingTodayModelUsageItem {
        .init(id:id,label:"GPT-6 Luna",tokens:100,share:0.5,costUSD:1,usesIndependentQuota:false,referenceCostUSD:nil,color:.blue)
    }
    func testClaudeVersionMetadataDoesNotUseReleaseDateAsVersion() {
        for (raw,version,label) in [("claude-opus-5-5-20261001",[5,5],"Opus 5.5"),("anthropic/claude-sonnet-4-6",[4,6],"Sonnet 4.6"),("claude-3-5-haiku-20241022",[3,5],"Haiku 3.5"),("claudeCode|fable5.1",[5,1],"Fable 5.1")] {
            XCTAssertEqual(ClaudeModelPresentation.identity(raw)?.version,version)
            XCTAssertEqual(ClaudeModelPresentation.identity(raw)?.label,label)
        }
        XCTAssertEqual(ClaudeModelPresentation.identity("claude-opus-20261001")?.version,[])
        XCTAssertNil(ClaudeModelPresentation.identity("unrelated-model"))
        let ids=["claudeCode|claude-opus-4-6","claudeCode|claude-opus-5-5","claudeCode|sonnet-5-5","claudeCode|fable5.1","claudeCode|custom"]
        let groups=ClaudeModelPresentation.groups(ids.map(item),client:"claudeCode")
        XCTAssertEqual(groups.first?.items.map(\.id),[ids[3],ids[1],ids[2]])
        XCTAssertEqual(groups.flatMap(\.items).map(\.id).sorted(),ids.sorted(),"No source row may disappear")
    }
    func testFloatingFilteringIsPresentationOnly() {
        let rows=[item("gpt-6-luna"),item("codex-auto-review@luna")]
        let compact=FloatingTodayModelUsagePresentation.compactItems(rows)
        XCTAssertEqual(compact.map(\.label),["6 Luna"])
        XCTAssertEqual(compact.first?.tokens,100)
        XCTAssertEqual(rows.count,2)
        XCTAssertNotEqual(ClientDisplayScope.key,ClientDisplayScope.sidebarKey)
    }
    func testRecentBodyReadingsExpireEvenWhenCollectorStops() {
        let sample=ModelSpeedSummary(model:"gpt-6.1-sol",tokensPerSecond:72,sampleCount:1,outputTokens:720,durationSeconds:10,lastMeasuredAt:100)
        XCTAssertEqual(RecentBodySpeed.readings([sample],now:1899),[sample])
        XCTAssertTrue(RecentBodySpeed.readings([sample],now:1901).isEmpty)
        XCTAssertEqual(RecentBodySpeed.nextExpiry([sample],now:1800),1900.002)
        var invalid=sample;invalid.sampleCount=2
        XCTAssertTrue(RecentBodySpeed.readings([invalid],now:101).isEmpty)
        XCTAssertTrue(RecentBodySpeed.readings([sample],now:99).isEmpty)
    }
    func testOnlyQuotaRoutesCarryOpaqueClientMarkers() throws {
        let ring=CGRect(x:10,y:10,width:46,height:46),track=CGRect(x:2,y:100,width:4,height:30)
        let routes=[ClientQuotaMorphRoute(id:"codex:7d",ring:ring,track:track,half:0,fraction:1,color:.green,marker:CGRect(x:27,y:65,width:5,height:5),markerColor:.blue),
                    ClientQuotaMorphRoute(id:"speed",ring:ring,track:track,half:0,fraction:0.5,color:.orange)]
        let markers=ClientQuotaMorphGeometry.strokes(routes).filter{$0.id.hasPrefix("marker:")}
        XCTAssertEqual(markers.count,1)
        let marker=try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.collapsed.points.first,CGPoint(x:track.midX,y:track.minY+2.5))
        XCTAssertEqual(marker.expanded.opacity,1);XCTAssertEqual(marker.collapsed.opacity,1)
        XCTAssertEqual(marker.color,.blue)
    }
    @MainActor func testNewFeaturesNativeRenderDoesNotEnableEitherOption() throws {
        var local=0,join=0
        let view=HarnessNewFeaturesView(offerLeaderboard:true,localClient:"Claude Code",localEnabled:false,
            enableLocal:{local+=1},joinLeaderboard:{join+=1},dismiss:{})
            .environment(\.colorScheme,.dark)
        let host=NSHostingView(rootView:view)
        host.frame=CGRect(x:0,y:0,width:570,height:740)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(local,0);XCTAssertEqual(join,0)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        if let folder=ProcessInfo.processInfo.environment["HARNESS_POLISH_PREVIEW_DIR"] {
            let directory=URL(fileURLWithPath:folder)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("new-features-native.png"))
        }
    }
}
