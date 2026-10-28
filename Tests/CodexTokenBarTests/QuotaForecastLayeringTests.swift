import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class QuotaForecastLayeringTests: XCTestCase {
    @MainActor func testForecastRemainsWhiteAboveTheOpaqueBrandDotNearFullQuota() throws {
        for expected in [1.0, 0.99, 0.98] {
            var item=ClientQuotaItem(id:"codex:7d",client:"codex",window:"7d",remaining:5,resetsAt:nil,source:"fixture",status:"")
            item.expected=expected
            let host=NSHostingView(rootView:ClientQuotaRailTrack(item:item,height:46,fillHex:"#ff0000").padding(8).background(Color.black))
            host.frame=CGRect(x:0,y:0,width:21,height:62);host.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
            let whiteRows=(0..<bitmap.pixelsHigh).filter { y in
                guard let color=bitmap.colorAt(x:bitmap.pixelsWide/2,y:y)?.usingColorSpace(.deviceRGB) else { return false }
                return min(color.redComponent,color.greenComponent,color.blueComponent)>0.85
            }
            XCTAssertFalse(whiteRows.isEmpty,"The white forecast may not be covered by the brand dot")
            let at=(8+2.5+43.5*(1-expected))*Double(bitmap.pixelsHigh)/62
            XCTAssertTrue(whiteRows.contains { min(abs(Double($0)-at),abs(Double($0)-(Double(bitmap.pixelsHigh)-at)))<3 })
        }
    }
    func testAnimatedForecastPaintsAfterTheBrandMarkerAndAllValueStrokes() throws {
        let route=ClientQuotaMorphRoute(id:"codex:7d",ring:CGRect(x:21,y:100,width:46,height:46),track:CGRect(x:6,y:250,width:5,height:46),
            half:0,fraction:0.8,color:.green,marker:CGRect(x:40,y:160,width:5,height:5),markerColor:.blue,expected:1)
        let strokes=ClientQuotaMorphGeometry.strokes([route])
        let forecast=try XCTUnwrap(strokes.last)
        XCTAssertEqual(forecast.id,"pace:codex:7d");XCTAssertEqual(forecast.color,.white)
        XCTAssertEqual(forecast.collapsed.points.first?.y,252.5)
        XCTAssertLessThan(try XCTUnwrap(strokes.firstIndex{$0.id=="marker:codex:7d"}),strokes.count-1)
    }
}
