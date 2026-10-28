import AppKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

final class SidebarBodyMedianTests: XCTestCase {
    private let end = 18_000.0
    private func row(_ at: Int64, _ tokens: Int64, seconds: Double = 1, count: Int64 = 2, model: String = "gpt-6.1-sol") -> BodySpeedTrendPoint {
        .init(bucketStart: at, model: model, outputTokens: tokens, durationSeconds: seconds, sampleCount: count, tokensPerSecond: Double(tokens)/seconds)
    }
    private var values: [BodySpeedTrendPoint] {
        [row(16_200,100,seconds:10), row(16_500,30), row(16_800,100)]
    }
    func testMedianOfBucketRatesNotWeightedOrSampleMedian() throws {
        let result = SidebarBodyMedian.project(values, now: end + 60)
        XCTAssertEqual(result.end, 18_000)
        let point = try XCTUnwrap(result.series.first?.current)
        XCTAssertEqual(point.median, 30)
        XCTAssertEqual(point.lower, 20)
        XCTAssertEqual(point.upper, 65)
        XCTAssertEqual(point.bucketCount, 3)
        XCTAssertEqual(point.sampleCount, 6)
        XCTAssertEqual(result.series.first?.slots.count, 6)
    }
    func testCurrentPartialHalfHourAndFutureAreExcluded() {
        XCTAssertTrue(SidebarBodyMedian.project(values, now: end-1).series.isEmpty)
        XCTAssertEqual(SidebarBodyMedian.project(values + [row(18_000,999),row(18_300,999),row(18_600,999)], now:end+1000), SidebarBodyMedian.project(values, now:end))
    }
    func testExpiredLatestIsNotReplacedByOlderValue() throws {
        let result=SidebarBodyMedian.project(values, now:end+1800)
        let series=try XCTUnwrap(result.series.first)
        XCTAssertNil(series.current)
        XCTAssertEqual(series.slots[4]?.median,30)
        XCTAssertEqual(series.slots.compactMap{$0}.count,1)
        XCTAssertTrue(SidebarBodyMedian.project(values,now:end+10800).series.isEmpty)
    }
    func testMinimumBucketAndSampleCountsAndDuplicates() throws {
        XCTAssertNil(SidebarBodyMedian.project(Array(values.prefix(2)),now:end).series.first?.current)
        XCTAssertNil(SidebarBodyMedian.project([row(16200,10,count:1),row(16500,20,count:1),row(16800,30,count:3)],now:end).series.first?.current)
        let series=try XCTUnwrap(SidebarBodyMedian.project(values+values,now:end).series.first)
        XCTAssertEqual(series.current?.bucketCount,3)
        XCTAssertEqual(series.current?.sampleCount,6)
    }
    func testModelIsolationAndInvalidNumbers() {
        let other=[row(16200,200,model:"gpt-6-luna"),row(16500,300,model:"gpt-6-luna"),row(16800,400,model:"gpt-6-luna")]
        let result=SidebarBodyMedian.project(values+other+[row(17100,100,seconds:.nan),row(17400,100,seconds:0),row(17701,999)],now:end)
        XCTAssertEqual(result.series.map{$0.current?.median},[300,30])
        XCTAssertTrue(SidebarBodyMedian.project(values,now:.nan).series.isEmpty)
    }
    func testEvenBucketInterpolationAndGapRemainExplicit() throws {
        let result=SidebarBodyMedian.project(values+[row(17100,50)],now:end)
        XCTAssertEqual(result.series.first?.current?.median,40)
        XCTAssertNil(result.series.first?.slots[4])
    }
    @MainActor func testNativeMiniViewFitsSidebarAndRenders() throws {
        let result=SidebarBodyMedian.project(values,now:end)
        let view=SidebarBodyMedianContent(snapshot:result,latest:[.init(model:"gpt-6.1-sol",tokensPerSecond:72,sampleCount:1,outputTokens:720,durationSeconds:10,lastMeasuredAt:end)],error:nil,onOpen:{})
            .frame(width:88).padding(.vertical,8).background(Color.black)
        let host=NSHostingView(rootView:view)
        host.frame=CGRect(x:0,y:0,width:88,height:160)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width,88)
        XCTAssertLessThan(host.fittingSize.height,160)
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        // Optional artifact for visual review, never an installed app launch.
        if let folder=ProcessInfo.processInfo.environment["SIDEBAR_MEDIAN_PREVIEW_DIR"] {
            let url=URL(fileURLWithPath:folder,isDirectory:true)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url.appendingPathComponent("native-sidebar-median.png"))
        }
    }
}
